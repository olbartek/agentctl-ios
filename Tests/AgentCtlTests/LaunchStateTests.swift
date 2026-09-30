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
        for (app, expected) in [("com.example.other", Int32(3)), (nil, 0), ("com.example.stub", 0)] as [(String?, Int32)] {
          let server = BridgeServer(app: app) { _ in BridgeResponse(status: 200, body: "state\n", exitCode: 0) }
          let port = Int(try await server.start(port: 0))
          var state = Self.state
          state.port = port
          try state.write(in: root)
          let fromFile = await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: nil) }
          let fromFlag = await CLICommandTests.withRepoRoot(root.path) { await AppCommands.get("/state", port: port) }
          server.stop()
          #expect(fromFile == expected, "\(app ?? "no header")")
          #expect(fromFlag == 0, "\(app ?? "no header")")
        }
        #expect(
          Message.anotherApp(port: 8766, answeredAs: "com.example.other", recorded: "com.example.stub")
            == "the app's agent bridge on 127.0.0.1:8766 answers as com.example.other, not com.example.stub from "
            + ".xctl/bridge.json, which is stale: relaunch with xctl app launch"
        )
      }

      @Test func aLaunchAnsweredByAnotherAppSaysSo() {
        AgentCtl.install(StubRuntime())
        #expect(
          Message.anotherApp(port: 8765, answeredAs: "com.example.other")
            == "the app's agent bridge on 127.0.0.1:8765 answers as com.example.other, not com.example.stub: "
            + "another app holds that port; pass --port or set APPCTL_PORT"
        )
        #expect(Message.anotherApp(port: 8765, answeredAs: nil).contains("answers as an app without X-Appctl-App, not"))
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
