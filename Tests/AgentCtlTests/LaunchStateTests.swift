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
        launchedAt: Date(timeIntervalSince1970: 1_790_000_000)
      )

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
              "port" : 8766
            }

            """
        )
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
        let server = BridgeServer { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        let port = Int(try await server.start(port: 0))
        #expect(!BridgePort.isFree(port))
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
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
        let server = BridgeServer { _ in BridgeResponse(status: 200, body: "state\n", exitCode: 0) }
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
        // The same app on Android is another app; a header the answer lacks is not compared.
        let answers: [(String?, String?, Int32)] = [
          ("com.example.other", "ios", 3), ("com.example.stub", "android", 3), (nil, nil, 0), ("com.example.stub", nil, 0),
          ("com.example.stub", "ios", 0),
        ]
        for (app, platform, expected) in answers {
          let server = BridgeServer(app: app, platform: platform) { _ in
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
        let server = BridgeServer(app: "com.example.other") { request in
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
    }
  }
#endif
