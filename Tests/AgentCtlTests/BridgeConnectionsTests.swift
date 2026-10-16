// The bridge is `#if DEBUG` from end to end, so its tests are too: in a release build there is nothing to test.
#if DEBUG
  @testable import AgentCtlBridge
  @testable import AgentCtlRuntime
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Network
  import Synchronization
  import Testing
  import TinyApp

  extension AgentCtlSuite {
    /// What this guards: the bridge's connections. A client that sends slowly, or nothing at all, holds up no other
    /// request, and has a deadline for its whole request; only so many connections are read at once; a header block
    /// over the limit is malformed however it arrives; a client that half-closes after its request is still answered;
    /// the running app's clock never traps however far it is advanced; and the listener survives a stop before it is
    /// ready and a failure after (CONTRACT.md §8.1, §2.2).
    @MainActor
    @Suite struct BridgeConnectionsTests {
      static let get = "GET /snapshot HTTP/1.1\r\nHost: x\r\n\r\n"

      func start(
        _ handler: @escaping BridgeServer.Handler = { _ in BridgeResponse(status: 200, body: "ok\n", exitCode: 0) }
      ) async throws -> (BridgeServer, UInt16) {
        let server = BridgeServer(app: "app", handler: handler)
        return (server, try await server.start(port: 0))
      }

      /// A client connection on the main queue, read to its end.
      final class Client {
        let connection: NWConnection

        init(port: UInt16) async throws {
          connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
          let connection = connection
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
              let result: Result<Void, any Error>
              switch state {
              case .ready: result = .success(())
              case let .failed(error), let .waiting(error): result = .failure(error)
              default: return
              }
              guard !resumed.withLock({ resumed in defer { resumed = true }; return resumed }) else { return }
              continuation.resume(with: result)
            }
            connection.start(queue: .main)
          }
        }

        func send(_ text: String) {
          connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        }

        /// Everything the bridge sends until it closes the connection; `""` when it closes without an answer.
        func readToEnd() async -> String {
          var received = Data()
          while true {
            let (data, done) = await withCheckedContinuation { continuation in
              connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete || error != nil))
              }
            }
            if let data { received.append(data) }
            if done { return String(decoding: received, as: UTF8.self) }
          }
        }

        func close() {
          connection.cancel()
        }
      }

      func request(_ text: String, port: UInt16) async throws -> String {
        let client = try await Client(port: port)
        defer { client.close() }
        client.send(text)
        return await client.readToEnd()
      }

      /// Polls `condition` for up to five seconds of real time.
      func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
          if await condition() { return }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
      }

      // MARK: - Reading (#53)

      @Test func anIdleConnectionHoldsUpNoOtherRequest() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        let idle = try await Client(port: port)
        defer { idle.close() }
        let started = ContinuousClock.now
        #expect(try await request(Self.get, port: port).hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(started.duration(to: .now) < .seconds(2))
      }

      /// The deadline is for the whole request, from accept: a byte now and then does not extend it.
      @Test func aSlowRequestIsIncompleteOnceItsDeadlinePasses() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        server.requestDeadline = .milliseconds(500)
        let slow = try await Client(port: port)
        defer { slow.close() }
        let started = ContinuousClock.now
        slow.send("GET /snap")
        try await Task.sleep(for: .milliseconds(300))
        slow.send("shot")
        let answer = await slow.readToEnd()
        #expect(answer.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(answer)")
        #expect(answer.contains("\r\nX-Appctl-Exit: 2\r\n"))
        #expect(answer.hasSuffix("\r\n\r\nincomplete request\n"), "\(answer)")
        #expect(started.duration(to: .now) < .seconds(3))
      }

      @Test func theDeadlineIsTenSecondsAndTheLimitSixteenConnections() {
        let server = BridgeServer(app: "app") { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        #expect(server.requestDeadline == .seconds(10))
        #expect(server.maxReadingConnections == 16)
      }

      /// A connection beyond the limit is closed unanswered; one that finished reading no longer counts.
      @Test func aConnectionBeyondTheLimitIsClosedWithoutAnAnswer() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        server.maxReadingConnections = 2
        let first = try await Client(port: port)
        let second = try await Client(port: port)
        defer { first.close(); second.close() }
        try await until { server.readingConnections == 2 }
        let third = try await Client(port: port)
        #expect(await third.readToEnd() == "")
        // Once one has sent its request, there is room again.
        first.send(Self.get)
        #expect(await first.readToEnd().hasPrefix("HTTP/1.1 200 OK\r\n"))
        try await until { server.readingConnections == 1 }
        #expect(try await request(Self.get, port: port).hasPrefix("HTTP/1.1 200 OK\r\n"))
      }

      // MARK: - The header limit (CONTRACT.md §8.1)

      @Test func aHeaderBlockOverTheLimitIsMalformedHoweverItArrives() async throws {
        let limit = HTTPParser.maxHeaderBytes
        #expect(limit == 65536)
        let padding = "X-Pad: " + String(repeating: "a", count: limit) + "\r\n"
        let whole = "GET /snapshot HTTP/1.1\r\nHost: x\r\n\(padding)\r\n"
        // With its blank line, and without it yet.
        #expect(HTTPParser.parse(Data(whole.utf8)) == .malformed)
        #expect(HTTPParser.parse(Data(whole.dropLast(4).utf8)) == .malformed)
        // Exactly at the limit, blank line included, it parses.
        let head = "GET / HTTP/1.1\r\nX: "
        let atTheLimit = head + String(repeating: "a", count: limit - head.utf8.count - 4) + "\r\n\r\n"
        #expect(atTheLimit.utf8.count == limit)
        #expect(HTTPParser.parse(Data(atTheLimit.utf8)) == .request(BridgeRequest(method: "GET", path: "/")))
        // Short of its blank line, a block at the limit may still end within it; one byte over cannot.
        #expect(HTTPParser.parse(Data(atTheLimit.dropLast(4).utf8)) == .incomplete)
        #expect(HTTPParser.parse(Data((head + String(repeating: "a", count: limit)).utf8)) == .malformed)

        // Over the wire, where it arrives in several reads, whole or still unfinished.
        let (server, port) = try await start()
        defer { server.stop() }
        for text in [whole, String(whole.dropLast(4))] {
          let answer = try await request(text, port: port)
          #expect(answer.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(answer.prefix(40))")
          #expect(answer.contains("\r\nX-Appctl-Exit: 2\r\n"))
          #expect(answer.hasSuffix("\r\n\r\nbad request\n"))
        }
      }

      // MARK: - A client that half-closes

      /// A client may close its sending side once its request is complete (`shutdown(SHUT_WR)`, `nc -N`): its request
      /// still runs, and it still gets the answer, however long the request takes.
      @Test func aClientThatHalfClosesAfterItsRequestIsAnswered() async throws {
        let (server, port) = try await start { _ in
          try? await Task.sleep(for: .milliseconds(300))
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        let client = try await Client(port: port)
        defer { client.close() }
        client.connection.send(content: Data(Self.get.utf8), isComplete: true, completion: .contentProcessed { _ in })
        let answer = await client.readToEnd()
        #expect(answer.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(answer)")
        #expect(answer.hasSuffix("\r\n\r\nok\n"))
      }

      // MARK: - The clock's offset (#55)

      /// Each runner has its own `advance` limit, as before; two runners on one running app's clock (the launch
      /// seed's and the bridge's) can each take all of it, and the date the clock then gives the app does not trap.
      @Test func twoRunnersOnOneClockCanEachAdvanceToTheLimit() async {
        let host = TinyAppConfig.live(latency: .zero)
        let seed = host.makeRunner(synthesizesAppearance: true)
        let bridge = host.makeRunner(synthesizesAppearance: false)
        #expect(await seed.run("advance 9223372036854775807s").status == .ok)
        #expect(await bridge.run("advance 9223372036854775807s").status == .ok)
        let refused = await bridge.run("advance 1s")
        #expect(refused.steps.first?.message == "advance would take the clock past 9223372036854775807 seconds")
        #expect(host.clock.base.date().timeIntervalSinceNow > 1.8e19)
      }

      /// However far it was moved, the date the clock gives the app never traps.
      @Test func theClocksDateNeverTraps() async {
        let clock = AdvanceableClock()
        await clock.advance(by: .seconds(Int.max))
        await clock.advance(by: .seconds(Int.max))
        #expect(clock.date().timeIntervalSinceNow > 1.8e19)
        // However many times: the offset stops at its cap.
        for _ in 0..<5 { await clock.advance(by: .seconds(Int.max)) }
        #expect(clock.offset == AdvanceableClock.maxOffset)
        _ = clock.now
        _ = clock.date()
      }

      // MARK: - The listener (#56)

      /// Whether the stop comes before the listener is ready is up to the system, so this tries a few times: every
      /// start ends (none waits forever), with a port or with `CancellationError`, and some stops come first.
      @Test func aStopBeforeTheListenerIsReadyEndsTheStart() async throws {
        var cancelled = 0
        for _ in 0..<20 {
          let server = BridgeServer(app: "app") { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
          let start = Task { try await server.start(port: 0) }
          while server.listener == nil { await Task.yield() }
          server.stop()
          switch await start.result {
          case .success: break
          case let .failure(error):
            #expect(error is CancellationError, "\(error)")
            cancelled += 1
          }
        }
        #expect(cancelled > 0)
      }

      /// A listener that fails once it is ready (the system taking the socket back) is restarted on the same port.
      @Test func aListenerThatFailsAfterItIsReadyIsRestarted() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        let failed = try #require(server.listener)
        server.listener(failed, changedTo: .failed(.posix(.ECONNABORTED)))
        var answer = ""
        try await until {
          guard server.listener !== failed, server.listener?.state == .ready else { return false }
          answer = (try? await request(Self.get, port: port)) ?? ""
          return !answer.isEmpty
        }
        #expect(answer.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(server.listener?.port?.rawValue == port)
      }
    }
  }
#endif
