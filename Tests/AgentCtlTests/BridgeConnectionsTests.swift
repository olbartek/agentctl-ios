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
      /// The launch's token, and the headers every request the bridge serves carries (CONTRACT.md §8.4).
      static let token = "0123456789abcdef0123456789abcdef"
      static let auth = "Host: 127.0.0.1\r\nX-Appctl-Token: \(token)\r\n"
      static let get = "GET /snapshot HTTP/1.1\r\n\(auth)\r\n"

      func start(
        _ handler: @escaping BridgeServer.Handler = { _ in BridgeResponse(status: 200, body: "ok\n", exitCode: 0) }
      ) async throws -> (BridgeServer, UInt16) {
        let server = BridgeServer(app: "app", token: Self.token, handler: handler)
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
          var noSignal: Int32 = 1
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
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

        /// Writes all of `text` off the main thread (a large write blocks until the bridge reads it).
        func sendAll(_ text: String) async {
          await Task.detached { [descriptor] in
            let bytes = Array(text.utf8)
            var sent = 0
            while sent < bytes.count {
              let count = bytes[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
              if count <= 0 { return }
              sent += count
            }
          }.value
        }

        private let readError = Mutex<Int32>(0)
        /// The errno of the read that ended ``readToEnd()``, or 0 when it ended at the bridge's clean close.
        var lastReadError: Int32 { readError.withLock { $0 } }

        /// Ends the sending side; the connection stays open for reading.
        func shutDownSending() {
          shutdown(descriptor, SHUT_WR)
        }

        /// Everything until the bridge closes the connection, read off the main thread (reads block).
        func readToEnd() async -> String {
          await Task.detached { [self] in
            var received = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
              let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
              if count < 0 { let code = errno; readError.withLock { $0 = code } }
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
        let server = BridgeServer(app: "app", token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
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

      // MARK: - The body cap (#69, CONTRACT.md §8.1)

      /// A `Content-Length` over 1 MiB is malformed as soon as the headers are in: the body is never waited for, and
      /// the request reaches no handler. Exactly 1 MiB is a request like any other.
      @Test func aBodyOverTheCapIsMalformedBeforeItIsRead() async throws {
        #expect(HTTPParser.maxBodyBytes == 1_048_576)
        let over = "POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 1048577\r\n\r\n"
        #expect(HTTPParser.parseHead(Data(over.utf8)) == .malformed)
        #expect(HTTPParser.parse(Data(over.utf8)) == .malformed)
        let atTheCap = "POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 1048576\r\n\r\n"
        #expect(HTTPParser.parse(Data(atTheCap.utf8)) == .incomplete)
        let whole = Data(atTheCap.utf8) + Data(repeating: 0x61, count: 1_048_576)
        guard case let .request(parsed) = HTTPParser.parse(whole) else {
          Issue.record("a body of exactly 1 MiB did not parse")
          return
        }
        #expect(parsed.body.utf8.count == 1_048_576)
        #expect(HTTPParser.parse(Data("GET / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n".utf8)) == .malformed)

        var handled = 0
        let (server, port) = try await start { _ in
          handled += 1
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        server.requestDeadline = .seconds(30)
        let started = ContinuousClock.now
        // Headers only, the body never sent: answered at once, not at the deadline. Without a token too: the cap
        // comes first.
        for text in [over, "POST /run HTTP/1.1\r\nContent-Length: 2097152\r\n\r\n"] {
          let answer = try await request(text, port: port)
          #expect(answer.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(answer)")
          #expect(answer.contains("\r\nX-Appctl-Exit: 2\r\n"))
          #expect(answer.contains("\r\nX-Appctl-App: app\r\nX-Appctl-Platform: ios\r\n"))
          #expect(answer.hasSuffix("\r\n\r\nbad request\n"))
        }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(handled == 0)
      }

      // MARK: - Strict headers (CONTRACT.md §8.1)

      /// Each of these is malformed while the headers are parsed, before Host, Origin or the token are looked at.
      static let malformedHeads: [(String, String)] = [
        ("a Transfer-Encoding", "POST /run HTTP/1.1\r\n\(auth)Transfer-Encoding: chunked\r\n\r\n"),
        ("a Transfer-Encoding beside a Content-Length", "POST /run HTTP/1.1\r\n\(auth)Content-Length: 3\r\ntransfer-encoding: identity\r\n\r\nabc"),
        ("two Content-Lengths that differ", "POST /run HTTP/1.1\r\n\(auth)Content-Length: 3\r\nContent-Length: 4\r\n\r\nabcd"),
        ("two identical Content-Lengths", "POST /run HTTP/1.1\r\n\(auth)Content-Length: 3\r\ncontent-length: 3\r\n\r\nabc"),
        ("a signed Content-Length", "POST /run HTTP/1.1\r\n\(auth)Content-Length: +3\r\n\r\nabc"),
        ("a negative Content-Length", "POST /run HTTP/1.1\r\n\(auth)Content-Length: -1\r\n\r\n"),
        ("a Content-Length with letters", "POST /run HTTP/1.1\r\n\(auth)Content-Length: 3a\r\n\r\nabc"),
        ("an empty Content-Length", "POST /run HTTP/1.1\r\n\(auth)Content-Length: \r\n\r\n"),
        ("a Content-Length of non-ASCII digits", "POST /run HTTP/1.1\r\n\(auth)Content-Length: \u{0663}\r\n\r\nabc"),
        ("a Content-Length of two numbers", "POST /run HTTP/1.1\r\n\(auth)Content-Length: 3 3\r\n\r\nabc"),
        ("a folded line (space)", "GET /snapshot HTTP/1.1\r\n\(auth)X-Note: a\r\n b\r\n\r\n"),
        ("a folded line (tab)", "GET /snapshot HTTP/1.1\r\n\(auth)X-Note: a\r\n\tb\r\n\r\n"),
        ("a space before the colon", "GET /snapshot HTTP/1.1\r\nHost : 127.0.0.1\r\nX-Appctl-Token: \(token)\r\n\r\n"),
        ("a tab before the colon", "GET /snapshot HTTP/1.1\r\n\(auth)Content-Length\t: 0\r\n\r\n"),
        ("a header without a name", "GET /snapshot HTTP/1.1\r\n\(auth): x\r\n\r\n"),
      ]

      @Test func strictHeadersAreMalformedWhileParsing() {
        for (name, text) in Self.malformedHeads {
          #expect(HTTPParser.parseHead(Data(text.utf8)) == .malformed, "\(name)")
          #expect(HTTPParser.parse(Data(text.utf8)) == .malformed, "\(name)")
        }
        // Optional whitespace around a value, spaces or tabs, is not part of it.
        let spaced = "POST /run HTTP/1.1\r\nHost:\t127.0.0.1 \r\nContent-Length:  3 \r\nX-Appctl-Token: \(Self.token)\t\r\n\r\nabc"
        #expect(HTTPParser.parse(Data(spaced.utf8)) == .request(BridgeRequest(method: "POST", path: "/run", body: "abc")))
        guard case let .head(head) = HTTPParser.parseHead(Data(spaced.utf8)) else {
          Issue.record("did not parse")
          return
        }
        #expect(head.value("Host") == "127.0.0.1")
        #expect(head.value("X-Appctl-Token") == Self.token)
        #expect(BridgeAccess.refusal(head, token: Self.token) == nil)
      }

      @Test func strictHeadersAreMalformedOverTheWire() async throws {
        var handled = 0
        let (server, port) = try await start { _ in
          handled += 1
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        for (name, text) in Self.malformedHeads {
          let answer = try await request(text, port: port)
          #expect(answer.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(name): \(answer)")
          #expect(answer.contains("\r\nX-Appctl-Exit: 2\r\n"), "\(name)")
          #expect(answer.hasSuffix("\r\n\r\nbad request\n"), "\(name)")
        }
        // Malformed comes before forbidden and unauthorized.
        let foreign = try await request("GET /snapshot HTTP/1.1\r\nOrigin: null\r\nTransfer-Encoding: chunked\r\n\r\n", port: port)
        #expect(foreign.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(handled == 0)
        // What URLSession sends passes: a Host with the port, a Content-Length, and its own other headers.
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/run")))
        request.httpMethod = "POST"
        request.httpBody = Data("open 1".utf8)
        request.setValue(Self.token, forHTTPHeaderField: "X-Appctl-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok\n")
        #expect(handled == 1)
      }

      // MARK: - A refusal is a whole answer and a clean close

      /// A request refused from its headers whose client has already sent a large body still gets the whole answer:
      /// the bridge ends its side and drops the rest, so the close is never a reset.
      @Test func aRefusedClientThatSentItsBodyReadsTheWholeAnswer() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        let megabyte = String(repeating: "a", count: 1_048_576)
        let cases: [(String, String, String)] = [
          ("POST /run HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Appctl-Token: \(BridgeToken.make())\r\nContent-Length: 1048576\r\n\r\n\(megabyte)",
           Self.unauthorized, "unauthorized\n"),
          ("POST /run HTTP/1.1\r\nHost: example.com\r\n\(Self.auth.split(separator: "\r\n")[1])\r\nContent-Length: 1048576\r\n\r\n\(megabyte)",
           Self.forbidden, "forbidden\n"),
          ("POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 2097152\r\n\r\n\(megabyte)\(megabyte)",
           "HTTP/1.1 400 Bad Request\r\n", "bad request\n"),
        ]
        for (text, status, body) in cases {
          let client = try SocketClient(port: port)
          let reading = Task { await client.readToEnd() }
          await client.sendAll(text)
          client.shutDownSending()
          let answer = await reading.value
          #expect(answer.hasPrefix(status), "\(answer.prefix(60))")
          #expect(answer.hasSuffix("\r\n\r\n\(body)"), "\(answer.prefix(200))")
          #expect(client.lastReadError == 0, "the answer ended in a reset: errno \(client.lastReadError)")
        }
      }

      // MARK: - Host, Origin and the token (#70, CONTRACT.md §8.4)

      /// What the bridge answers a `GET /snapshot` with these header lines, and whether it reached the handler.
      func answer(_ headers: [String], server: (BridgeServer, UInt16), handled: () -> Int) async throws -> (String, Bool) {
        let before = handled()
        let text = "GET /snapshot HTTP/1.1\r\n" + headers.map { "\($0)\r\n" }.joined() + "\r\n"
        let answer = try await request(text, port: server.1)
        return (answer, handled() > before)
      }

      static let forbidden = "HTTP/1.1 403 Forbidden\r\n"
      static let unauthorized = "HTTP/1.1 401 Unauthorized\r\n"

      @Test func onlyLoopbackHostNamesAreServedWhateverThePort() async throws {
        var handled = 0
        let server = try await start { _ in
          handled += 1
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.0.stop() }
        let token = "X-Appctl-Token: \(Self.token)"
        for host in ["127.0.0.1", "127.0.0.1:\(server.1)", "127.0.0.1:1", "localhost", "localhost:8765", "LocalHost:9", "LOCALHOST", "localhost:", "127.0.0.1:"] {
          let (answer, reached) = try await self.answer(["Host: \(host)", token], server: server) { handled }
          #expect(answer.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(host): \(answer)")
          #expect(reached, "\(host)")
        }
        let foreign = [
          "example.com", "example.com:\(server.1)", "127.0.0.2", "127.0.0.1.example.com", "localhost.example.com",
          "[::1]:\(server.1)", "[::1]", "0.0.0.0", "", ":8765", "local\u{17F}host", "localhost:abc", "localhost:8765x",
          "localhost:-1", "localhost: 8765", "localhost:\u{0668}", "127.0.0.1:80:80", "\u{FF4C}ocalhost", "localhost.",
        ]
        for host in foreign {
          let (answer, reached) = try await self.answer(["Host: \(host)", token], server: server) { handled }
          #expect(answer.hasPrefix(Self.forbidden), "\(host): \(answer)")
          #expect(!reached, "\(host)")
        }
        // No Host at all, and a second Host, loopback or not: repeated values are joined with ", ", so never match.
        for headers in [[token], ["Host: 127.0.0.1", "Host: example.com", token], ["Host: 127.0.0.1", "host: 127.0.0.1", token]] {
          let (answer, reached) = try await self.answer(headers, server: server) { handled }
          #expect(answer.hasPrefix(Self.forbidden), "\(headers): \(answer)")
          #expect(!reached)
        }
      }

      /// Any Origin is refused, a loopback one included: a browser sends one, the CLI never does.
      @Test func aRequestWithAnOriginIsForbidden() async throws {
        var handled = 0
        let server = try await start { _ in
          handled += 1
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.0.stop() }
        for origin in ["Origin: http://127.0.0.1:\(server.1)", "Origin: null", "origin: http://example.com"] {
          let (answer, reached) = try await self.answer(
            ["Host: 127.0.0.1", "X-Appctl-Token: \(Self.token)", origin], server: server
          ) { handled }
          #expect(answer.hasPrefix(Self.forbidden), "\(origin): \(answer)")
          #expect(answer.contains("\r\nX-Appctl-Exit: 3\r\n"))
          #expect(answer.contains("\r\nX-Appctl-App: app\r\nX-Appctl-Platform: ios\r\n"))
          #expect(answer.hasSuffix("\r\n\r\nforbidden\n"))
          #expect(!reached)
        }
      }

      @Test func onlyTheLaunchsTokenIsServed() async throws {
        var handled = 0
        let server = try await start { _ in
          handled += 1
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.0.stop() }
        let other = BridgeToken.make()
        let wrong = [
          [], ["X-Appctl-Token: "], ["X-Appctl-Token: \(other)"], ["X-Appctl-Token: \(Self.token.uppercased())"],
          ["X-Appctl-Token: \(Self.token.dropLast())"], ["X-Appctl-Token: \(Self.token)0"],
          ["X-Appctl-Token: \(Self.token)", "X-Appctl-Token: \(other)"], ["X-Appctl-Tokens: \(Self.token)"],
          // Sent twice, even the same token: the values are joined, so it is not 32 hex characters.
          ["X-Appctl-Token: \(Self.token)", "x-appctl-token: \(Self.token)"],
        ]
        for headers in wrong {
          let (answer, reached) = try await self.answer(["Host: 127.0.0.1"] + headers, server: server) { handled }
          #expect(answer.hasPrefix(Self.unauthorized), "\(headers): \(answer)")
          #expect(answer.contains("\r\nX-Appctl-Exit: 3\r\n"))
          #expect(answer.contains("\r\nX-Appctl-App: app\r\nX-Appctl-Platform: ios\r\n"))
          #expect(answer.hasSuffix("\r\n\r\nunauthorized\n"))
          #expect(!reached, "\(headers)")
        }
        // The header's name is matched without regard to case, as HTTP's are.
        for name in ["X-Appctl-Token", "x-appctl-token", "X-APPCTL-TOKEN"] {
          let (answer, reached) = try await self.answer(["Host: 127.0.0.1", "\(name): \(Self.token)"], server: server) {
            handled
          }
          #expect(answer.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(name): \(answer)")
          #expect(answer.hasSuffix("\r\n\r\nok\n"))
          #expect(reached)
        }
      }

      /// Malformed, then forbidden, then unauthorized, then routing: the first that applies answers. A refusal is
      /// decided from the headers, so a body that never comes is not waited for.
      @Test func theChecksComeInOrder() async throws {
        var handled = 0
        let server = try await start { _ in
          handled += 1
          return BridgeResponse(status: 404, body: "not found\n", exitCode: 2)
        }
        defer { server.0.stop() }
        server.0.requestDeadline = .seconds(30)
        let cases: [(String, String)] = [
          // Over the cap, without a Host, with an Origin and no token: malformed.
          ("POST /run HTTP/1.1\r\nOrigin: http://example.com\r\nContent-Length: 1048577\r\n\r\n", "HTTP/1.1 400 Bad Request\r\n"),
          // No Host and no token: forbidden.
          ("GET /snapshot HTTP/1.1\r\n\r\n", Self.forbidden),
          // A foreign Host with the right token, and an Origin with a wrong one: forbidden.
          ("GET /snapshot HTTP/1.1\r\nHost: example.com\r\nX-Appctl-Token: \(Self.token)\r\n\r\n", Self.forbidden),
          ("GET /snapshot HTTP/1.1\r\nHost: localhost\r\nOrigin: null\r\nX-Appctl-Token: x\r\n\r\n", Self.forbidden),
          // A loopback Host and a wrong token, the body still to come: unauthorized at once.
          ("POST /run HTTP/1.1\r\nHost: localhost\r\nX-Appctl-Token: x\r\nContent-Length: 10\r\n\r\n", Self.unauthorized),
          // A foreign Host, the body still to come: forbidden at once.
          ("POST /run HTTP/1.1\r\nHost: example.com\r\n\(Self.auth.split(separator: "\r\n")[1])\r\nContent-Length: 10\r\n\r\n", Self.forbidden),
          // Everything in order: routing, which here answers 404.
          ("GET /nowhere HTTP/1.1\r\n\(Self.auth)\r\n", "HTTP/1.1 404 Not Found\r\n"),
        ]
        let started = ContinuousClock.now
        for (text, status) in cases {
          let answer = try await request(text, port: server.1)
          #expect(answer.hasPrefix(status), "\(text.debugDescription): \(answer)")
        }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(handled == 1)
      }

      /// A refusal is answered at once, never queued behind a request that is running; an authorized request whose body
      /// does not come is answered as incomplete once its deadline passes, as before.
      @Test func aRefusalIsNotQueuedAndAnUnfinishedBodyIsStillIncomplete() async throws {
        let (server, port) = try await start { request in
          if request.path == "/slow" { try? await Task.sleep(for: .seconds(30)) }
          return BridgeResponse(status: 200, body: "ok\n", exitCode: 0)
        }
        defer { server.stop() }
        server.requestDeadline = .milliseconds(500)
        let slow = try await Client(port: port)
        defer { slow.close() }
        slow.send("GET /slow HTTP/1.1\r\n\(Self.auth)\r\n")
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        #expect(try await request("GET /snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", port: port).hasPrefix(Self.unauthorized))
        #expect(try await request("GET /snapshot HTTP/1.1\r\n\r\n", port: port).hasPrefix(Self.forbidden))
        #expect(started.duration(to: .now) < .milliseconds(400), "a refusal waited")
        let unfinished = try await request("POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 10\r\n\r\nopen", port: port)
        #expect(unfinished.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), "\(unfinished)")
        #expect(unfinished.hasSuffix("\r\n\r\nincomplete request\n"))
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
        let request = "POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: \(script.utf8.count)\r\n\r\n\(script)"
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
        client.send("GET /slow HTTP/1.1\r\n\(Self.auth)\r\n")
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
        gone.send("POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: \(script.utf8.count)\r\n\r\n\(script)")
        try await Task.sleep(for: .milliseconds(200))
        gone.close()
        try await until { !app.outcomes.isEmpty }
        #expect(app.outcomes == ["cancelled"])
        let started = ContinuousClock.now
        let next = try await request(
          "POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 14\r\n\r\nexpect items=3", port: port
        )
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(next.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(next)")
        #expect(next.contains("\r\nX-Appctl-Exit: 0\r\n"), "\(next)")
        // The fetch the cancelled run started finishes on its own; then the app settles as usual.
        let after = try await request("POST /run HTTP/1.1\r\n\(Self.auth)Content-Length: 7\r\n\r\nrefresh", port: port)
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
        slow.send("GET /slow HTTP/1.1\r\n\(Self.auth)\r\n")
        try await until { ran == ["/slow"] }
        let queued = try await Client(port: port)
        queued.send("GET /queued HTTP/1.1\r\n\(Self.auth)\r\n")
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
          let server = BridgeServer(app: "app", token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
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
