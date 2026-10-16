#if os(macOS) && DEBUG
  import AgentCtlBridge
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: how the `app` commands find the app's bridge. A launch picks a free port and records it in
    /// `<outputPath>/bridge.json`; the commands that talk to the running app read it back. `--port` beats
    /// `APPCTL_PORT`, which beats the file, which beats 8765. The file's bytes are shared with agentctl-android.
    @MainActor
    @Suite struct LaunchStateTests {
      static let state = LaunchState(
        device: "5C0A5A2E-0000-4000-8000-000000000001", port: 8766, appId: "com.example.stub",
        launchedAt: Date(timeIntervalSince1970: 1_790_000_000), token: "0123456789abcdef0123456789abcdef"
      )
      static let token = state.token!

      /// Sorted keys, Foundation's pretty form, no escaped slashes, one trailing newline: the same bytes as the
      /// Kotlin port writes.
      @Test func theFileIsSortedPrettyJSONWithATrailingNewline() throws {
        #expect(
          try Self.state.encoded() == """
            {
              "appId" : "com.example.stub",
              "device" : "5C0A5A2E-0000-4000-8000-000000000001",
              "launchedAt" : "2026-09-21T14:13:20Z",
              "platform" : "ios",
              "port" : 8766,
              "token" : "0123456789abcdef0123456789abcdef"
            }

            """
        )
      }

      /// The file holds the token, so only its owner may read it: 0600 when it is new, and when it was there before
      /// with another mode.
      @Test func theFileIsReadableByItsOwnerOnly() throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LaunchState.file(in: root)
        func mode() throws -> Int {
          try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        }
        try Self.state.write(in: root)
        #expect(try mode() == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try mode() == 0o644)
        try Self.state.write(in: root)
        #expect(try mode() == 0o600)
        #expect(try LaunchState.read(in: root) == Self.state)
        // Nothing is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["bridge.json"])
      }

      /// A file from before 0.9 has no token: it still reads, and its bridge then answers 401.
      @Test func aFileWithoutATokenReads() throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = Self.state
        state.token = nil
        try state.write(in: root)
        #expect(!(try String(contentsOf: LaunchState.file(in: root), encoding: .utf8)).contains("token"))
        #expect(try LaunchState.read(in: root)?.token == nil)
      }

      /// `APPCTL_TOKEN`, as `APPCTL_PORT` does for the port, beats the file (an empty one is unset); the file's token
      /// goes only to the port it records; otherwise there is none.
      @Test func theTokenComesFromTheVariableThenTheFileForItsPort() throws {
        let file = { () -> LaunchState? in Self.state }
        let none = { () -> LaunchState? in nil }
        let variable = ["APPCTL_TOKEN": "fedcba9876543210fedcba9876543210"]
        #expect(try BridgeTokenSource.connecting(port: 8766, environment: variable, launchState: file) == variable["APPCTL_TOKEN"])
        #expect(try BridgeTokenSource.connecting(port: 9000, environment: variable, launchState: none) == variable["APPCTL_TOKEN"])
        #expect(try BridgeTokenSource.connecting(port: 8766, environment: [:], launchState: file) == Self.token)
        #expect(try BridgeTokenSource.connecting(port: 8766, environment: ["APPCTL_TOKEN": ""], launchState: file) == Self.token)
        #expect(try BridgeTokenSource.connecting(port: 9000, environment: [:], launchState: file) == nil)
        #expect(try BridgeTokenSource.connecting(port: 8766, environment: [:], launchState: none) == nil)
        #expect(BridgeTokenSource.environmentVariable == "APPCTL_TOKEN")
      }

      /// An `APPCTL_TOKEN` that is not a token is a usage error (exit 2), like a bad `APPCTL_PORT`, and its value is
      /// never echoed: it could hold a line break, or a secret meant for something else.
      @Test func aMalformedTokenVariableIsAUsageError() {
        for value in ["FEDCBA9876543210FEDCBA9876543210", "abc", "fedcba9876543210fedcba9876543210\r\nX: y", "secret-value-123"] {
          let error = #expect(throws: UsageError.self, "\(value)") {
            try BridgeTokenSource.connecting(port: 8766, environment: ["APPCTL_TOKEN": value]) { Self.state }
          }
          #expect(error?.description == "APPCTL_TOKEN is not a token (32 lowercase hex characters)")
          #expect(AppCommands.fail(error!) == 2)
        }
      }

      /// The CLI makes a fresh token for every launch: 32 lowercase hex characters, never the same twice.
      @Test func aLaunchTokenIsThirtyTwoLowercaseHexCharactersAndFresh() {
        let tokens = (0..<100).map { _ in BridgeToken.make() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
          #expect(token.count == 32)
          #expect(token.allSatisfy { "0123456789abcdef".contains($0) }, "\(token)")
          #expect(BridgeToken.isWellFormed(token))
        }
        #expect(BridgeToken.argument == "-agent-token")
        #expect(BridgeToken.header == "X-Appctl-Token")
      }

      @Test func onlyThirtyTwoLowercaseHexCharactersAreAToken() {
        #expect(BridgeToken.isWellFormed("0123456789abcdef0123456789abcdef"))
        for token in [
          "", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0", "0123456789ABCDEF0123456789abcdef",
          "0123456789abcdeg0123456789abcdef", " 0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcde\u{0662}",
          "０123456789abcdef0123456789abcdef",
        ] {
          #expect(!BridgeToken.isWellFormed(token), "\(token)")
        }
        #expect(BridgeToken.matches(Self.token, Self.token))
        #expect(!BridgeToken.matches(Self.token, String(Self.token.reversed())))
        #expect(!BridgeToken.matches(Self.token + "0", Self.token))
        #expect(!BridgeToken.matches("", Self.token))
      }

      /// The token is never printed, logged or dumped: not in the state's or the client's description or dump, and
      /// not in a command line the CLI writes to a log.
      @Test func theTokenIsNeverPrinted() {
        var dumped = ""
        dump(Self.state, to: &dumped)
        let client = BridgeClient(port: 8766, token: Self.token)
        var dumpedClient = ""
        dump(client, to: &dumpedClient)
        for text in [
          "\(Self.state)", String(reflecting: Self.state), dumped, "\(client)", String(reflecting: client), dumpedClient,
          Shell.redacted(["xcrun", "simctl", "launch", "U", "com.example.stub", "-agent-token", Self.token, "-agent-port", "8766"])
            .joined(separator: " "),
        ] {
          #expect(!text.contains(Self.token), "\(text)")
        }
        #expect("\(Self.state)".contains("token: <redacted>"))
        #expect(
          Shell.redacted(["launch", "-agent-token", Self.token, "-clear-session"]) == ["launch", "-agent-token", "<redacted>", "-clear-session"]
        )
        #expect(Shell.redacted(["launch", "-agent-token"]) == ["launch", "-agent-token"])
      }

      /// A launch that times out notes its command line in the log, without the token.
      @Test func aTimedOutCommandLineIsLoggedWithoutTheToken() throws {
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "launch.log")
        let status = Shell.run(["/bin/sh", "-c", "sleep 5", "sh", "-agent-token", Self.token], in: root, log: log, timeout: 0.2)
        #expect(status == Shell.timedOut)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("-agent-token <redacted>"), "\(text)")
        #expect(!text.contains(Self.token))
      }

      /// A 401 and a 403 are exit 3, each with its own message, naming the CLI as the host calls it.
      @Test func aRefusalSaysWhy() {
        AgentCtl.install(StubRuntime())
        #expect(
          Message.refusedToken(port: 8766)
            == "the app's agent bridge on 127.0.0.1:8766 refused the token (relaunch it: xctl app launch)"
        )
        #expect(Message.forbidden(port: 8766) == "the app's agent bridge on 127.0.0.1:8766 refused the request (forbidden)")
        func response(_ status: Int) -> BridgeClient.Response {
          BridgeClient.Response(
            status: status, body: "x\n", exitCode: 3, identity: BridgeIdentity(app: "com.example.stub", platform: "ios")
          )
        }
        #expect(response(401).refusal(port: 8766) == BridgeClient.Refused(port: 8766, reason: .token))
        #expect(response(403).refusal(port: 8766) == BridgeClient.Refused(port: 8766, reason: .forbidden))
        #expect(response(200).refusal(port: 8766) == nil)
        #expect(response(404).refusal(port: 8766) == nil)
        // A 401 or 403 without X-Appctl-Exit is not a bridge's refusal.
        var other = response(401)
        other.carriesExit = false
        #expect(other.refusal(port: 8766) == nil)
        other.status = 403
        #expect(other.refusal(port: 8766) == nil)
        // Another app's refusal is another app: its "answers as" text wins.
        var android = response(401)
        android.identity = BridgeIdentity(app: "com.example.stub", platform: "android")
        #expect(AppTest.foreign(android, port: 8766).map { AppTest.Result(name: "b", outcome: $0).report }?.contains("answers as") == true)
        // However the port was found: the message is the refusal's alone.
        let refused = BridgeClient.Refused(port: 8766, reason: .token)
        #expect(Message.bridgeUnreachable(port: 8766, source: .launchState(Self.state), error: refused) == Message.refusedToken(port: 8766))
        #expect("\(BridgeClient.Refused(port: 8766, reason: .forbidden))" == Message.forbidden(port: 8766))
        #expect(AppCommands.fail(refused) == 3)
        // `app test`: a scenario the app refused is not run (exit 3), like one another app answered.
        let outcome = AppTest.foreign(response(401), port: 8766)
        #expect(
          outcome.map { AppTest.Result(name: "browse", outcome: $0).report }
            == "FAIL browse\n  the app's agent bridge on 127.0.0.1:8766 refused the token (relaunch it: xctl app launch)"
        )
        #expect(outcome.map { AppTest.Result(name: "browse", outcome: $0).isBroken } == true)
        #expect(AppTest.foreign(response(403), port: 8766).map { AppTest.Result(name: "b", outcome: $0).isBroken } == true)
        #expect(AppTest.foreign(response(200), port: 8766) == nil)
      }

      @Test func theFileLivesInTheOutputDirectoryAndRoundTrips() throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try LaunchState.read(in: root) == nil)
        try Self.state.write(in: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".xctl/bridge.json").path))
        #expect(LaunchState.relativePath == ".xctl/bridge.json")
        #expect(try LaunchState.read(in: root) == Self.state)
      }

      @Test func anUnreadableFileSaysHowToRecover() throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".xctl"), withIntermediateDirectories: true)
        try "{ not json".write(to: root.appending(path: ".xctl/bridge.json"), atomically: true, encoding: .utf8)
        #expect {
          try LaunchState.read(in: root)
        } throws: { error in
          "\(error)".hasPrefix("cannot read .xctl/bridge.json: ") && "\(error)".contains("relaunch with xctl app launch")
        }
      }

      @Test func connectingPrefersTheFlagThenTheVariableThenTheFileThenTheDefault() throws {
        let file = { () throws -> LaunchState? in Self.state }
        let none = { () throws -> LaunchState? in nil }
        let variable = ["APPCTL_PORT": "9001"]
        #expect(try BridgePort.connecting(flag: 9000, environment: variable, launchState: file) == (9000, .flag))
        #expect(try BridgePort.connecting(flag: nil, environment: variable, launchState: file) == (9001, .environment))
        #expect(
          try BridgePort.connecting(flag: nil, environment: [:], launchState: file) == (8766, .launchState(Self.state))
        )
        #expect(try BridgePort.connecting(flag: nil, environment: [:], launchState: none) == (8765, .defaultPort))
        #expect(try BridgePort.connecting(flag: nil, environment: ["APPCTL_PORT": ""], launchState: none).port == 8765)
      }

      @Test func aBadPortVariableIsAUsageError() {
        for value in ["abc", "0", "65536", "-1", "80 80"] {
          #expect(throws: UsageError.self, "\(value)") {
            try BridgePort.requested(flag: nil, environment: ["APPCTL_PORT": value])
          }
        }
        #expect(Message.badPortVariable("abc") == "APPCTL_PORT is not a port: 'abc' (expected 1-65535)")
        #expect(AppCommands.fail(UsageError("x")) == 2)
        #expect(AppCommands.fail(AppCtlError("x")) == 3)
      }

      @Test func launchingTakesTheRequestedPortAsIsOrTheFirstFreeOneFrom8765() throws {
        #expect(try BridgePort.launching(requested: 9000, isFree: { _ in false }) == 9000)
        #expect(try BridgePort.launching(requested: nil, isFree: { _ in true }) == 8765)
        #expect(try BridgePort.launching(requested: nil, isFree: { $0 > 8767 }) == 8768)
        #expect(throws: AppCtlError.self) { try BridgePort.launching(requested: nil, isFree: { _ in false }) }
        #expect(BridgePort.scanned == 8765...8864)
        #expect(
          Message.noFreePort == "no free port for the app's agent bridge in 8765-8864: pass --port or set APPCTL_PORT"
        )
      }

      /// A port something listens on is taken, even when a bind with address reuse (as the bridge does) would
      /// succeed; it is free again once the listener closes.
      @Test func aPortIsFreeOnlyWhenNothingListensOnIt() async throws {
        let server = BridgeServer(token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        let port = Int(try await server.start(port: 0))
        #expect(!BridgePort.isFree(port))
        server.stop()
        // The listener closes asynchronously, so poll for up to five seconds rather than sleep a fixed time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !BridgePort.isFree(port), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
        #expect(BridgePort.isFree(port))
        #expect(!BridgePort.isFree(70000))
      }

      /// A listener on `::1` can sit beside the bridge's `127.0.0.1` (an `adb forward` did, in the incident that added
      /// this): the port is taken, though a bind on `127.0.0.1` would succeed.
      @Test func aListenerOnIPv6LoopbackTakesThePort() throws {
        let (descriptor, port) = try Self.listen(on: .ipv6)
        defer { close(descriptor) }
        #expect(BridgePort.Loopback.ipv4.canBind(port), "the old probe's bind would have called it free")
        #expect(!BridgePort.isFree(Int(port)))
      }

      /// A wildcard listener that no longer accepts (its backlog is full): a connect is not refused, it hangs, and a
      /// bind on `127.0.0.1` beside the wildcard succeeds. The port is taken, and the probe answers within seconds.
      @Test func aListenerThatNoLongerAcceptsTakesThePort() throws {
        let (descriptor, port) = try Self.listen(on: .ipv4, wildcard: true, backlog: 1)
        defer { close(descriptor) }
        var fillers: [Int32] = []
        defer { fillers.forEach { close($0) } }
        for _ in 0..<8 {
          let filler = socket(AF_INET, SOCK_STREAM, 0)
          _ = fcntl(filler, F_SETFL, fcntl(filler, F_GETFL) | O_NONBLOCK)
          var address = sockaddr_in()
          address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          address.sin_family = sa_family_t(AF_INET)
          address.sin_port = port.bigEndian
          address.sin_addr.s_addr = inet_addr("127.0.0.1")
          _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              connect(filler, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
          fillers.append(filler)
        }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(!BridgePort.isFree(Int(port)))
        #expect(start.duration(to: clock.now) < .seconds(5))
      }

      /// A BSD listener on loopback (or the wildcard address) of `family`, on a port the system picks.
      static func listen(
        on family: BridgePort.Loopback, wildcard: Bool = false, backlog: Int32 = 16
      ) throws -> (Int32, UInt16) {
        let descriptor = socket(family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var result: Int32
        var port: UInt16 = 0
        if family == .ipv4 {
          var address = sockaddr_in()
          address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          address.sin_family = sa_family_t(AF_INET)
          address.sin_addr.s_addr = wildcard ? INADDR_ANY : inet_addr("127.0.0.1")
          var size = socklen_t(MemoryLayout<sockaddr_in>.size)
          result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              bind(descriptor, $0, size) == 0 && Darwin.listen(descriptor, backlog) == 0
                && getsockname(descriptor, $0, &size) == 0 ? 0 : -1
            }
          }
          port = UInt16(bigEndian: address.sin_port)
        } else {
          var address = sockaddr_in6()
          address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
          address.sin6_family = sa_family_t(AF_INET6)
          address.sin6_addr = in6addr_loopback
          var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
          result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              bind(descriptor, $0, size) == 0 && Darwin.listen(descriptor, backlog) == 0
                && getsockname(descriptor, $0, &size) == 0 ? 0 : -1
            }
          }
          port = UInt16(bigEndian: address.sin6_port)
        }
        try #require(result == 0 && port != 0)
        return (descriptor, port)
      }

      /// End to end: with no `--port`, `app state` reaches the bridge the launch state names.
      @Test func theAppCommandsReachTheBridgeTheLastLaunchRecorded() async throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The app the launch state names, as its bridge says.
        let server = BridgeServer(app: "com.example.stub", token: Self.token) { _ in
          BridgeResponse(status: 200, body: "state\n", exitCode: 0)
        }
        let port = Int(try await server.start(port: 0))
        defer { server.stop() }
        var state = Self.state
        state.port = port
        try state.write(in: root)
        let code = await CLICommandTests.withRepoRoot(root.path) {
          await AppCommands.get("/state", port: nil)
        }
        #expect(code == 0)
        let connection = await CLICommandTests.withRepoRoot(root.path) { try? AppCommands.connection(flag: nil) }
        #expect(connection?.port == port)
      }

      /// End to end: the file's token reaches the bridge with the port it records, through `--port` too; a token that
      /// is not the launch's, or none (a port the file does not name), is refused with exit 3.
      @Test func theFilesTokenReachesTheBridgeAndAnotherIsRefused() async throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var seen: [String] = []
        let server = BridgeServer(app: "com.example.stub", token: Self.token) { request in
          seen.append("\(request.method) \(request.path)")
          return BridgeResponse(status: 200, body: "> open 1\n", exitCode: 0)
        }
        let port = Int(try await server.start(port: 0))
        defer { server.stop() }
        var state = Self.state
        state.port = port
        try state.write(in: root)
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: nil) } == 0)
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: port) } == 0)
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.run(script: "open 1", json: false, port: nil) } == 0)
        #expect(seen == ["GET /state", "GET /state", "GET /snapshot", "POST /run"])
        // A stale token: the script is never posted.
        state.token = BridgeToken.make()
        try state.write(in: root)
        seen = []
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.run(script: "open 1", json: false, port: nil) } == 3)
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: nil) } == 3)
        // No file: no token.
        try FileManager.default.removeItem(at: LaunchState.file(in: root))
        #expect(await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: port) } == 3)
        #expect(seen.isEmpty)
        // And straight from the client: its refusal, which names the port.
        let answer = try await BridgeClient(port: port, token: nil).send("GET", "/state")
        #expect(answer.status == 401)
        #expect(answer.exitCode == 3)
        #expect(answer.identity == BridgeIdentity(app: "com.example.stub", platform: "ios"))
        #expect(answer.refusal(port: port) == BridgeClient.Refused(port: port, reason: .token))
      }

      /// The build's `.app`, from XcodeBuildMCP's report; anything else is not a path to install.
      @Test func theBuiltAppIsReadFromGetAppPath() {
        let report = """
          ✅ Get app path successful (⏱️ 9.1s)
            └ Files:
               └ App Path: ~/Library/DerivedData/X/Build/Products/Debug-iphonesimulator/Stub App.app

          """
        #expect(
          Simulator.appPath(fromGetAppPath: report)?.path
            == NSHomeDirectory() + "/Library/DerivedData/X/Build/Products/Debug-iphonesimulator/Stub App.app"
        )
        #expect(Simulator.appPath(fromGetAppPath: "❌ Get app path failed") == nil)
        #expect(Simulator.appPath(fromGetAppPath: "App Path: /tmp/not-an-app") == nil)
      }

      /// With the port from the file, an answer from another app is refused rather than printed; one that does not
      /// name itself (an app built before the header) is accepted, and a port named by `--port` is not checked.
      @Test func aRecordedPortThatAnotherAppAnswersOnIsStale() async throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The same app on Android is another app, and so is an answer without either header: the launch that wrote
        // bridge.json checked both.
        let answers: [(String?, String?, Int32)] = [
          ("com.example.other", "ios", 3), ("com.example.stub", "android", 3), (nil, nil, 3), ("com.example.stub", nil, 3),
          ("com.example.stub", "ios", 0),
        ]
        for (app, platform, expected) in answers {
          let server = BridgeServer(app: app, platform: platform, token: Self.token) { _ in
            BridgeResponse(status: 200, body: "state\n", exitCode: 0)
          }
          let port = Int(try await server.start(port: 0))
          var state = Self.state
          state.port = port
          try state.write(in: root)
          let fromFile = await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: nil) }
          let fromFlag = await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: port) }
          server.stop()
          #expect(fromFile == expected, "\(app ?? "no app") (\(platform ?? "no platform"))")
          #expect(fromFlag == 0, "\(app ?? "no app") (\(platform ?? "no platform"))")
        }
        #expect(
          Message.anotherApp(
            port: 8766, answeredAs: BridgeIdentity(app: "com.example.stub", platform: "android"), recorded: Self.state
          )
            == "the app's agent bridge on 127.0.0.1:8766 answers as com.example.stub (android), not com.example.stub "
            + "(ios) from .xctl/bridge.json, which is stale: relaunch with xctl app launch"
        )
      }

      @Test func aLaunchAnsweredByAnotherAppSaysSo() {
        AgentCtl.install(StubRuntime())
        #expect(
          Message.portHeld(port: 8765)
            == "the app's agent bridge could not listen on 127.0.0.1:8765: another process holds that port; "
            + "pass --port or set APPCTL_PORT"
        )
        #expect(
          Message.anotherApp(port: 8765, answeredAs: BridgeIdentity(app: "com.example.stub", platform: "android"))
            == "the app's agent bridge on 127.0.0.1:8765 answers as com.example.stub (android), not com.example.stub "
            + "(ios): another app holds that port; pass --port or set APPCTL_PORT"
        )
        #expect(
          Message.anotherApp(port: 8765, answeredAs: BridgeIdentity(app: nil, platform: nil))
            == "the app's agent bridge on 127.0.0.1:8765 answers as an app without X-Appctl-App (no X-Appctl-Platform), "
            + "not com.example.stub (ios): another app holds that port; pass --port or set APPCTL_PORT (or the installed "
            + "app predates X-Appctl-App: launch without --no-build)"
        )
        #expect(
          Message.anotherApp(port: 8765, answeredAs: BridgeIdentity(app: "com.example.stub", platform: nil))
            .hasSuffix("(or the installed app predates X-Appctl-Platform: launch without --no-build)")
        )
        // At launch every header must be there and match: the same app on Android, or without a platform, is not ours.
        #expect(BridgeIdentity(app: "com.example.stub", platform: "ios").isOurs)
        #expect(!BridgeIdentity(app: "com.example.stub", platform: "android").isOurs)
        #expect(!BridgeIdentity(app: "com.example.stub", platform: nil).isOurs)
        #expect(
          Message.anotherAppAnswered(port: 8766, answeredAs: BridgeIdentity(app: "com.example.stub", platform: "android"))
            == "the app's agent bridge on 127.0.0.1:8766 answers as com.example.stub (android), not com.example.stub "
            + "(ios): another app took the port during the run"
        )
      }

      /// A script is not posted to another app on the recorded port: only the identity check reaches it.
      @Test func aScriptIsNotPostedToAnotherAppOnTheRecordedPort() async throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var requests: [String] = []
        let server = BridgeServer(app: "com.example.other", token: Self.token) { request in
          requests.append("\(request.method) \(request.path)")
          return BridgeResponse(status: 200, body: "> open 1\n", exitCode: 0)
        }
        let port = Int(try await server.start(port: 0))
        defer { server.stop() }
        var state = Self.state
        state.port = port
        try state.write(in: root)
        let code = await CLICommandTests.withRepoRoot(root.path) {
          await AppCommands.run(script: "open 1", json: false, port: nil)
        }
        #expect(code == 3)
        #expect(requests == ["GET /snapshot"])
      }

      /// A stale file names itself and says to relaunch; a port that did not come from it keeps the old message.
      @Test func anUnreachableRecordedPortSaysTheFileMayBeStale() {
        AgentCtl.install(StubRuntime())
        let stale = Message.bridgeUnreachable(port: 8766, source: .launchState(Self.state), error: StubError())
        #expect(
          stale == "cannot reach the app's agent bridge on 127.0.0.1:8766 (is the app running? xctl app launch): "
            + "connection refused; the port is from .xctl/bridge.json (launched 2026-09-21T14:13:20Z on "
            + "5C0A5A2E-0000-4000-8000-000000000001), which is stale once that app has quit: relaunch with xctl app launch"
        )
        #expect(
          Message.bridgeUnreachable(port: 8765, source: .defaultPort, error: StubError())
            == Message.bridgeUnreachable(port: 8765, error: StubError())
        )
      }

      /// The `.app` to install without XcodeBuildMCP: the application in `xcodebuild -showBuildSettings -json`, which
      /// need not be named after the scheme.
      @Test func theBuiltAppIsReadFromTheBuildSettings() {
        let settings = """
          [
            {"action": "build", "target": "MyKit", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.framework",
              "TARGET_BUILD_DIR": "/dd/Build/Products/Debug-iphonesimulator", "FULL_PRODUCT_NAME": "MyKit.framework"}},
            {"action": "build", "target": "MyApp-Dev", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application",
              "TARGET_BUILD_DIR": "/dd/Build/Products/Dev-iphonesimulator", "FULL_PRODUCT_NAME": "MyApp.app"}}
          ]
          """
        #expect(Simulator.appPath(fromBuildSettings: settings)?.path == "/dd/Build/Products/Dev-iphonesimulator/MyApp.app")
        #expect(Simulator.appPath(fromBuildSettings: "xcodebuild: error: no scheme") == nil)
        #expect(Simulator.appPath(fromBuildSettings: "[]") == nil)
      }

      /// The bridge answers `POST /run` only once the script is done, so a script may be silent for longer than a
      /// request that runs nothing may be: it is not cut off, and one past its own limit says so rather than calling
      /// the bridge unreachable.
      @Test func aLongScriptIsNotAnUnreachableBridge() async throws {
        AgentCtl.install(StubRuntime())
        let server = BridgeServer(app: "com.example.stub", token: Self.token) { request in
          if request.method == "POST" { try? await Task.sleep(for: .seconds(2)) }
          return BridgeResponse(status: 200, body: "> open 1\n", exitCode: 0)
        }
        let port = Int(try await server.start(port: 0))
        defer { server.stop() }
        let client = BridgeClient(port: port, token: Self.token)
        let answer = try await BridgeClient.$idleTimeout.withValue(0.5) {
          try await client.send("POST", "/run", body: "open 1")
        }
        #expect(answer.body == "> open 1\n")
        let error = await BridgeClient.$scriptLimit.withValue(1) { () async -> (any Error)? in
          do { _ = try await client.send("POST", "/run", body: "open 1") } catch { return error }
          return nil
        }
        let timedOut = try #require(error as? BridgeClient.ScriptTimedOut)
        #expect(
          Message.bridgeUnreachable(port: port, source: .launchState(Self.state), error: timedOut)
            == "the app did not finish the script within 1 s (agent bridge on 127.0.0.1:\(port)); it may still be running it"
        )
        // Waiting for the first answer before the next request: the bridge handles one at a time.
        try await Task.sleep(for: .seconds(2))
      }
    }
  }
#endif
