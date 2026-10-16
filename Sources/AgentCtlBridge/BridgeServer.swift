#if DEBUG
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation
  import Network
  import OSLog

  /// A tiny HTTP server on `127.0.0.1` (never another interface) that hands requests to a handler on the main
  /// actor, one at a time.
  ///
  /// Every connection is read on its own, and only a complete request joins the queue, so a client that sends slowly,
  /// or nothing at all, holds up no one else: it has ``requestDeadline`` from accept to send its whole request, and at
  /// most ``maxReadingConnections`` connections are read at once. A client that closes its side of the connection
  /// before the answer has gone away: its request is cancelled, queued or running, and gets no answer (CONTRACT.md
  /// §8.1), so the next request does not wait behind it.
  @MainActor
  public final class BridgeServer {
    /// Answers a request. A handler that throws — `CancellationError` when its client has gone away — sends no
    /// answer: the connection is closed, and the bridge goes on serving.
    public typealias Handler = @MainActor (BridgeRequest) async throws -> BridgeResponse

    private let handler: Handler
    /// The launch's token: every request must carry it as `X-Appctl-Token` (CONTRACT.md §8.4).
    private let token: String
    /// Sent as `X-Appctl-App` on every response.
    private let app: String?
    private let platform: String?
    private(set) var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    /// The port the listener got, so a listener the system took back is restarted on the same one.
    private var boundPort: UInt16?
    /// Whether ``listener`` has been ready: a failure after that is the system taking it back, not a failed start.
    private var listenerWasReady = false
    /// Restarts in a row that failed before they were ready.
    private var failedRestarts = 0
    private var restartTask: Task<Void, Never>?
    private var isStopped = false
    /// Requests run one after another, in the order they are complete.
    private var lastRequest: Task<Void, Never>?
    /// The connections still reading their request.
    private var reading: [ObjectIdentifier: Exchange] = [:]
    /// How many connections are reading their request now.
    var readingConnections: Int { reading.count }

    /// How long a connection has, from accept, to send its whole request; after that it is answered as incomplete.
    var requestDeadline: Duration = .seconds(10)
    /// How many connections may be reading a request at once. One more is closed without an answer.
    var maxReadingConnections = 16
    /// How many restarts in a row may fail before the bridge stops trying.
    static let maxFailedRestarts = 5

    private static var log: Logger { Logger(subsystem: "agentctl", category: "bridge") }

    /// - Parameter app: the app's bundle ID, sent on every response as `X-Appctl-App` so a CLI can tell whether the
    ///   app on the port is the one it launched.
    /// - Parameter platform: sent as `X-Appctl-Platform` beside the app; tests name another platform, or none, to play
    ///   the same app on Android or one built before the header.
    /// - Parameter token: the launch's `-agent-token`. A request without it in `X-Appctl-Token` is answered 401, and one
    ///   addressed to another Host or sent with an Origin 403, before it reaches `handler` (CONTRACT.md §8.4).
    public init(
      app: String? = Bundle.main.bundleIdentifier, platform: String? = BridgeDefaults.platform, token: String,
      handler: @escaping Handler
    ) {
      self.app = app
      self.platform = platform
      self.token = token
      self.handler = handler
    }

    /// Starts listening and returns the bound port (pass 0 for an ephemeral port). Throws when the port cannot be
    /// bound, and when ``stop()`` comes first.
    public func start(port: UInt16) async throws -> UInt16 {
      let listener = try Self.makeListener(port: port)
      isStopped = false
      return try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
        listen(listener)
      }
    }

    public func stop() {
      isStopped = true
      restartTask?.cancel()
      restartTask = nil
      listener?.cancel()
      listener = nil
      startContinuation?.resume(throwing: CancellationError())
      startContinuation = nil
      for exchange in reading.values {
        close(exchange)
      }
    }

    private static func makeListener(port: UInt16) throws -> NWListener {
      let parameters = NWParameters.tcp
      // Address reuse lets a relaunch rebind while the last run's connections are in TIME_WAIT. It never lets the
      // bridge listen beside another listener on the port: that bind fails (CONTRACT.md §8.1).
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: port) ?? .any
      )
      return try NWListener(using: parameters)
    }

    private func listen(_ listener: NWListener) {
      self.listener = listener
      listenerWasReady = false
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        MainActor.assumeIsolated {
          guard let self, let listener else { return }
          self.listener(listener, changedTo: state)
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        MainActor.assumeIsolated { self?.accept(connection) }
      }
      listener.start(queue: .main)
    }

    func listener(_ listener: NWListener, changedTo state: NWListener.State) {
      // A listener stopped or replaced since: its news is old.
      guard listener === self.listener else { return }
      switch state {
      case .ready:
        let port = listener.port?.rawValue ?? 0
        if boundPort != nil {
          Self.log.notice("listening again on 127.0.0.1:\(port, privacy: .public)")
        }
        boundPort = port
        listenerWasReady = true
        failedRestarts = 0
        startContinuation?.resume(returning: port)
        startContinuation = nil
      case let .failed(error):
        listener.cancel()
        if let continuation = startContinuation {
          self.listener = nil
          startContinuation = nil
          continuation.resume(throwing: error)
        } else if listenerWasReady {
          // The system took the socket back (an app suspended on a device, say): listen again on the same port, so
          // the bridge keeps answering.
          Self.log.error("listener failed: \(error.debugDescription, privacy: .public); restarting it")
          restart()
        } else {
          failedRestarts += 1
          guard failedRestarts < Self.maxFailedRestarts else {
            Self.log.error("could not listen again: \(error.debugDescription, privacy: .public); giving up")
            self.listener = nil
            return
          }
          Self.log.error("could not listen again: \(error.debugDescription, privacy: .public); retrying")
          restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.restart()
          }
        }
      case .cancelled:
        self.listener = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
      default:
        break
      }
    }

    private func restart() {
      guard !isStopped, let port = boundPort else { return }
      do {
        listen(try Self.makeListener(port: port))
      } catch {
        Self.log.error("could not listen again: \(String(describing: error), privacy: .public)")
        listener = nil
      }
    }

    // MARK: - Connections

    /// One connection, from accept until it is answered or closed.
    @MainActor
    private final class Exchange {
      enum Phase {
        /// Reading the request, against the deadline.
        case reading
        /// The request is complete, and queued or running.
        case handling
        /// Answered or closed: nothing more happens on it.
        case done
      }

      let connection: NWConnection
      var phase = Phase.reading
      var buffer = Data()
      var deadline: Task<Void, Never>?
      var request: Task<Void, Never>?

      init(_ connection: NWConnection) {
        self.connection = connection
      }
    }

    private func accept(_ connection: NWConnection) {
      guard reading.count < maxReadingConnections else {
        connection.cancel()
        return
      }
      let exchange = Exchange(connection)
      reading[ObjectIdentifier(exchange)] = exchange
      connection.stateUpdateHandler = { [weak self] state in
        MainActor.assumeIsolated {
          switch state {
          // A reset, once the request is in. While it is still being read, the read sees the failure itself.
          case .failed where exchange.phase == .handling: self?.abandon(exchange)
          default: break
          }
        }
      }
      connection.start(queue: .main)
      exchange.deadline = Task { [weak self, requestDeadline] in
        do {
          try await Task.sleep(for: requestDeadline)
        } catch {
          return
        }
        guard let self, exchange.phase == .reading else { return }
        self.answer(exchange, with: BridgeResponse(status: 400, body: "incomplete request\n", exitCode: 2))
      }
      receive(on: exchange)
    }

    private func receive(on exchange: Exchange) {
      exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] data, _, isComplete, error in
        MainActor.assumeIsolated {
          guard let self, exchange.phase == .reading else { return }
          if let data { exchange.buffer.append(data) }
          // Malformed (a body over the cap included), then forbidden, then unauthorized: each decided from the
          // headers alone, so a refused request's body is never read (CONTRACT.md §8.1, §8.4).
          switch HTTPParser.parseHead(exchange.buffer) {
          case let .head(head):
            if let refusal = BridgeAccess.refusal(head, token: self.token) {
              self.answer(exchange, with: refusal)
            } else if let request = HTTPParser.request(head, in: exchange.buffer) {
              self.enqueue(request, on: exchange)
              // Its side closed with the request's last bytes: it has gone away already.
              if isComplete || error != nil { self.abandon(exchange) }
            } else if isComplete || error != nil {
              self.answer(exchange, with: BridgeResponse(status: 400, body: "incomplete request\n", exitCode: 2))
            } else {
              self.receive(on: exchange)
            }
          case .malformed:
            self.answer(exchange, with: BridgeResponse(status: 400, body: "bad request\n", exitCode: 2))
          case .incomplete:
            if isComplete || error != nil {
              self.answer(exchange, with: BridgeResponse(status: 400, body: "incomplete request\n", exitCode: 2))
            } else {
              self.receive(on: exchange)
            }
          }
        }
      }
    }

    /// Ends the reading phase: the connection no longer counts against the limit, and its deadline is off.
    private func stopReading(_ exchange: Exchange) {
      reading[ObjectIdentifier(exchange)] = nil
      exchange.deadline?.cancel()
      exchange.deadline = nil
    }

    private func enqueue(_ request: BridgeRequest, on exchange: Exchange) {
      stopReading(exchange)
      exchange.phase = .handling
      let previous = lastRequest
      let handler = handler
      let task = Task { @MainActor [weak self] in
        await previous?.value
        do {
          // Its client went away while it waited: nothing to run it for.
          try Task.checkCancellation()
          let response = try await handler(request)
          self?.answer(exchange, with: response)
        } catch is CancellationError {
          Self.log.notice("cancelled: its client went away")
          self?.close(exchange)
        } catch {
          let what = "\(request.method) \(request.path)"
          Self.log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
          self?.close(exchange)
        }
      }
      exchange.request = task
      lastRequest = task
      watchForClose(exchange)
    }

    /// While a request waits or runs, the client may close its side of the connection, which ends its stream (a
    /// half-close, a close or a reset alike): it has gone away (CONTRACT.md §8.1).
    private func watchForClose(_ exchange: Exchange) {
      exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        [weak self] _, _, isComplete, error in
        MainActor.assumeIsolated {
          guard let self, exchange.phase == .handling else { return }
          if isComplete || error != nil {
            self.abandon(exchange)
          } else {
            // Bytes after the request: one request per connection, so they are dropped.
            self.watchForClose(exchange)
          }
        }
      }
    }

    /// The client went away before its answer: cancel its request, so the next one does not wait behind it, and
    /// close the connection unanswered.
    private func abandon(_ exchange: Exchange) {
      guard exchange.phase == .handling else { return }
      exchange.request?.cancel()
      close(exchange)
    }

    private func close(_ exchange: Exchange) {
      guard exchange.phase != .done else { return }
      stopReading(exchange)
      exchange.phase = .done
      exchange.connection.stateUpdateHandler = nil
      exchange.connection.cancel()
    }

    private func answer(_ exchange: Exchange, with response: BridgeResponse) {
      guard exchange.phase != .done else { return }
      stopReading(exchange)
      exchange.phase = .done
      let connection = exchange.connection
      connection.stateUpdateHandler = nil
      // The answer ends this side of the connection (a FIN, not a reset); what the client still sends, such as the
      // body of a request refused from its headers, is read and dropped until it closes its side, so the close never
      // turns into a reset that could cost the client the answer.
      let linger = lingerLimit
      connection.send(
        content: HTTPParser.serialize(response, app: app, platform: platform),
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { _ in Self.drain(connection, for: linger) }
      )
    }

    /// How long an answered connection may go on sending before it is closed regardless.
    var lingerLimit: Duration = .seconds(2)

    /// Reads and drops what `connection` still sends, then closes it once the client has closed its side, or once
    /// `limit` has passed.
    private nonisolated static func drain(_ connection: NWConnection, for limit: Duration) {
      let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { connection.cancel() }
      discard(connection)
    }

    private nonisolated static func discard(_ connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, isComplete, error in
        if isComplete || error != nil {
          connection.cancel()
        } else {
          discard(connection)
        }
      }
    }
  }

  /// A dump of the server never shows its token.
  extension BridgeServer: CustomReflectable {
    public nonisolated var customMirror: Mirror {
      Mirror(self, children: ["token": BridgeToken.redacted], displayStyle: .class)
    }
  }
#endif
