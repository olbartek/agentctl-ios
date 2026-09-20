#if DEBUG
  import AgentCtlTCA
  import Foundation
  import Network

  /// A tiny HTTP server on `127.0.0.1` (never another interface) that hands requests to a handler on the main
  /// actor, one at a time.
  @MainActor
  public final class BridgeServer {
    public typealias Handler = @MainActor (BridgeRequest) async -> BridgeResponse

    private let handler: Handler
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    /// Requests run one after another, in arrival order.
    private var lastRequest: Task<Void, Never>?

    public init(handler: @escaping Handler) {
      self.handler = handler
    }

    /// Starts listening and returns the bound port (pass 0 for an ephemeral port).
    public func start(port: UInt16) async throws -> UInt16 {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: port) ?? .any
      )
      let listener = try NWListener(using: parameters)
      self.listener = listener
      return try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
        listener.stateUpdateHandler = { [weak self] state in
          MainActor.assumeIsolated { self?.listenerStateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
          MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
      }
    }

    public func stop() {
      listener?.cancel()
      listener = nil
    }

    private func listenerStateChanged(_ state: NWListener.State) {
      switch state {
      case .ready:
        startContinuation?.resume(returning: listener?.port?.rawValue ?? 0)
        startContinuation = nil
      case let .failed(error):
        startContinuation?.resume(throwing: error)
        startContinuation = nil
      default:
        break
      }
    }

    private func accept(_ connection: NWConnection) {
      connection.start(queue: .main)
      receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
        MainActor.assumeIsolated {
          guard let self else { return }
          var buffer = buffer
          if let data { buffer.append(data) }
          switch HTTPParser.parse(buffer) {
          case let .request(request):
            self.enqueue(request, on: connection)
          case .malformed:
            self.send(BridgeResponse(status: 400, body: "bad request\n", exitCode: 2), on: connection)
          case .incomplete:
            if isComplete || error != nil {
              self.send(BridgeResponse(status: 400, body: "incomplete request\n", exitCode: 2), on: connection)
            } else {
              self.receive(on: connection, buffer: buffer)
            }
          }
        }
      }
    }

    private func enqueue(_ request: BridgeRequest, on connection: NWConnection) {
      let previous = lastRequest
      let handler = handler
      lastRequest = Task { @MainActor [weak self] in
        await previous?.value
        let response = await handler(request)
        self?.send(response, on: connection)
      }
    }

    private func send(_ response: BridgeResponse, on connection: NWConnection) {
      connection.send(
        content: HTTPParser.serialize(response),
        completion: .contentProcessed { _ in connection.cancel() }
      )
    }
  }
#endif
