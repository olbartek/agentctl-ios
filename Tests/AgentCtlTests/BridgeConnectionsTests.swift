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
    /// over the limit is malformed however it arrives; a client that closes its side before the answer has gone away,
    /// so its request is cancelled without leaving the app half-settled; the running app's clock never traps however
    /// far it is advanced; and the listener survives a stop before it is ready and a failure after (CONTRACT.md §8.1,
    /// §2.2).
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

      /// A plain BSD socket, for `shutdown(SHUT_WR)`: a client that ends its sending side and still reads.
      final class SocketClient: Sendable {
        let descriptor: Int32

        init(port: UInt16) throws {
          descriptor = socket(AF_INET, SOCK_STREAM, 0)
          var address = sockaddr_in()
          address.sin_family = sa_family_t(AF_INET)
          address.sin_port = port.bigEndian
          address.sin_addr.s_addr = inet_addr("127.0.0.1")
          let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
          guard connected == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
          }
        }

        func send(_ text: String) {
          _ = Array(text.utf8).withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        }

        /// Ends the sending side; the connection stays open for reading.
        func shutDownSending() {
          shutdown(descriptor, SHUT_WR)
        }

        /// Everything until the bridge closes the connection, read off the main thread (reads block).
        func readToEnd() async -> String {
          await Task.detached { [descriptor] in
            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
              let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
              if count <= 0 { break }
              received += buffer[0..<count]
            }
            return String(decoding: received, as: UTF8.self)
          }.value
        }

        deinit {
          Darwin.close(descriptor)
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

      // MARK: - A client that goes away (#54, CONTRACT.md §8.1)

      /// A live TinyApp whose every fetch takes `latency`, behind a bridge that records how each `/run` ended: its
      /// body, or `cancelled` when the run threw `CancellationError`.
      final class SlowApp {
        var started = 0
        var outcomes: [String] = []
      }

      func startSlowApp(latency: Duration = .seconds(3)) async throws -> (BridgeServer, UInt16, SlowApp) {
        let host = TinyAppConfig.live(latency: .fixed(latency))
        let runner = host.makeRunner(synthesizesAppearance: true)
        _ = await runner.launch()
        let router = BridgeRouter(runner: runner, screensText: { "" })
        let app = SlowApp()
        let (server, port) = try await start { request in
          guard request.path == "/run" else { return try await router.handle(request) }
          app.started += 1
          do {
            let response = try await router.handle(request)
            app.outcomes.append(response.body)
            return response
          } catch {
            app.outcomes.append(error is CancellationError ? "cancelled" : "\(error)")
            throw error
          }
        }
        return (server, port, app)
      }

      /// A client that half-closes once its request is complete (`shutdown(SHUT_WR)`) has gone away: its script is
      /// cancelled and it gets no answer.
      @Test func aClientThatHalfClosesAfterItsRequestGetsNoAnswer() async throws {
        let (server, port, app) = try await startSlowApp()
        defer { server.stop() }
        let client = try SocketClient(port: port)
        let script = "refresh; expect loading=false"
        let request = "POST /run HTTP/1.1\r\nContent-Length: \(script.utf8.count)\r\n\r\n\(script)"
        client.send(request)
        try await until { app.started == 1 }
        let started = ContinuousClock.now
        // While the script runs, the client ends its sending side and waits for an answer.
        client.shutDownSending()
        #expect(await client.readToEnd() == "")
        try await until { !app.outcomes.isEmpty }
        #expect(started.duration(to: .now) < .seconds(2), "the script ran its course")
        #expect(app.outcomes == ["cancelled"])
      }

      /// A client whose sending side ends right after its request's last bytes has gone away too: no answer, and
      /// the request, if it started at all, is cancelled. The bridge goes on serving.
      @Test func aRequestFollowedAtOnceByTheEndOfItsSideGetsNoAnswer() async throws {
        var finished: [String] = []
        let (server, port) = try await start { request in
          if request.path == "/slow" {
            try await Task.sleep(for: .seconds(1))
          }
          finished.append(request.path)
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        let client = try SocketClient(port: port)
        client.send("GET /slow HTTP/1.1\r\n\r\n")
        client.shutDownSending()
        #expect(await client.readToEnd() == "")
        #expect(try await request(Self.get, port: port).hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(finished == ["/snapshot"])
      }

      /// A client that disconnects while its script runs cancels it, and the next request is answered promptly, from
      /// a host in a state it can go on from.
      @Test func aClientThatDisconnectsMidRunLetsTheNextRequestThrough() async throws {
        let (server, port, app) = try await startSlowApp(latency: .milliseconds(1500))
        defer { server.stop() }
        let gone = try await Client(port: port)
        let script = "refresh; refresh"
        gone.send("POST /run HTTP/1.1\r\nContent-Length: \(script.utf8.count)\r\n\r\n\(script)")
        try await Task.sleep(for: .milliseconds(200))
        gone.close()
        try await until { !app.outcomes.isEmpty }
        #expect(app.outcomes == ["cancelled"])
        let started = ContinuousClock.now
        let next = try await request(
          "POST /run HTTP/1.1\r\nContent-Length: 14\r\n\r\nexpect items=3", port: port
        )
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(next.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(next)")
        #expect(next.contains("\r\nX-Appctl-Exit: 0\r\n"), "\(next)")
        // The fetch the cancelled run started finishes on its own; then the app settles as usual.
        let after = try await request("POST /run HTTP/1.1\r\nContent-Length: 7\r\n\r\nrefresh", port: port)
        #expect(after.contains("\r\nX-Appctl-Exit: 0\r\n"), "\(after)")
        #expect(!after.contains("settled=false"))
      }

      /// A request queued behind one whose client went away is cancelled too when its own client goes, and never runs.
      @Test func aQueuedRequestWhoseClientGoesAwayNeverRuns() async throws {
        var ran: [String] = []
        let (server, port) = try await start { request in
          ran.append(request.path)
          if request.path == "/slow" { try? await Task.sleep(for: .seconds(30)) }
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        let slow = try await Client(port: port)
        slow.send("GET /slow HTTP/1.1\r\n\r\n")
        try await until { ran == ["/slow"] }
        let queued = try await Client(port: port)
        queued.send("GET /queued HTTP/1.1\r\n\r\n")
        try await Task.sleep(for: .milliseconds(100))
        queued.close()
        slow.close()
        let started = ContinuousClock.now
        #expect(try await request(Self.get, port: port).hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(ran == ["/slow", "/snapshot"])
      }

      /// A cancelled run throws `CancellationError` at once, the line it was on cut short and no further line run;
      /// the app is left as that line left it, and the next run settles as usual.
      @Test func aCancelledRunThrowsWithoutLeavingTheAppHalfSettled() async throws {
        let runner = TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
        _ = await runner.launch()
        let run = Task { try await runner.run("open 2; back; open 1") }
        // Cancelled while `open 2` settles.
        try await until { runner.snapshot(command: "").screen == "items/2" }
        let started = ContinuousClock.now
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(runner.snapshot(command: "").screen == "items/2", "a line after the cancelled one ran")
        let next = try await runner.run("expect screen=items/2; back")
        #expect(next.status == .ok, "\(StepFormatter.text(next.steps))")
        #expect(next.steps.allSatisfy { $0.settled })
      }

      /// A cancelled launch seed aborts the launch: it throws, rather than reporting a failed seed.
      @Test func aCancelledSeedAbortsTheLaunch() async throws {
        let seed = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          return try await AgentLaunch<AgentStoreDriver<TinyRoot>>.applySeed(
            "open 2", with: TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
          )
        }
        await #expect(throws: CancellationError.self) { _ = try await seed.value }
      }

      /// A cancelled `advance` still moves the clock all the way, without waiting for the app between deadlines.
      @Test func aCancelledAdvanceGoesToTheEnd() async {
        let clock = AdvanceableClock()
        let advance = Task {
          withUnsafeCurrentTask { $0?.cancel() }
          await clock.advance(by: .seconds(3600), between: { Issue.record("waited for the app") })
        }
        await advance.value
        #expect(clock.offset == .seconds(3600))
      }

      // MARK: - The clock's offset (#55)

      /// Each runner has its own `advance` limit, as before; two runners on one running app's clock (the launch
      /// seed's and the bridge's) can each take all of it, and the date the clock then gives the app does not trap.
      @Test func twoRunnersOnOneClockCanEachAdvanceToTheLimit() async throws {
        let host = TinyAppConfig.live(latency: .zero)
        let seed = host.makeRunner(synthesizesAppearance: true)
        let bridge = host.makeRunner(synthesizesAppearance: false)
        #expect(try await seed.run("advance 9223372036854775807s").status == .ok)
        #expect(try await bridge.run("advance 9223372036854775807s").status == .ok)
        let refused = try await bridge.run("advance 1s")
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
