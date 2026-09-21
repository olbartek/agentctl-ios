#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import ArgumentParser
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: the CLI's exit codes (CONTRACT.md §5) where they do not come straight from a script —
    /// ArgumentParser's usage errors, a launch that never settles, a `test` run with nothing to run, a scenario
    /// file that does not exist, and a repo root that cannot be found.
    ///
    /// The commands run in-process against ``StubRuntime``, installed as the CLI's host the way
    /// `AgentCtl.run(config:)` installs a real one.
    @MainActor
    @Suite struct CLICommandTests {
      /// ArgumentParser exits 64 for its own usage errors; the contract's code for every usage error is 2.
      @Test func argumentParserUsageErrorsExitTwo() {
        AgentCtl.install(StubRuntime())
        let usageErrors = [["run"], ["run", "--bogus", "x"], ["frobnicate"], ["app", "run", "--port", "x", "open 1"]]
        for arguments in usageErrors {
          let error = Self.parseError(arguments)
          #expect(error != nil, "\(arguments) parsed")
          #expect(error.map(AgentCtl.exitStatus(for:)) == 2, "\(arguments)")
        }
        for arguments in [["--help"], ["-h"], ["run", "--help"], ["app", "launch", "--help"]] {
          let error = Self.parseError(arguments)
          #expect(error.map(AgentCtl.exitStatus(for:)) == 0, "\(arguments)")
        }
        // A subcommand's own failures keep their codes.
        #expect(AgentCtl.exitStatus(for: ExitCode(1)) == 1)
        #expect(AgentCtl.exitStatus(for: ExitCode(3)) == 3)
      }

      /// With no `--port`, the `app` commands connect where the app listens by default.
      @Test func theAppCommandsDefaultToTheBridgesDefaultPort() throws {
        AgentCtl.install(StubRuntime())
        #expect(try BridgeOptions.parse([]).port == Int(BridgeDefaults.port))
        #expect(try BridgeOptions.parse(["--port", "9000"]).port == 9000)
      }

      @Test func aLaunchThatNeverSettlesFailsTheRun() async {
        AgentCtl.install(StubRuntime.restless)
        let text = await serially {
          await Commands.run(script: "expect screen=restless", sessionPath: nil, diff: false, json: false)
        }
        let json = await serially {
          await Commands.run(script: "expect screen=restless", sessionPath: nil, diff: false, json: true)
        }
        #expect(text == 1)
        #expect(json == 1)
      }

      @Test func aLaunchThatNeverSettlesFailsTheTestCommand() async throws {
        AgentCtl.install(StubRuntime.restless)
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "restless.appctl")
        try "expect screen=restless\n".write(to: file, atomically: true, encoding: .utf8)
        let code = await serially { await Commands.test(paths: [file.path]) }
        #expect(code == 1)
      }

      /// "0 passed, 0 failed" is not a pass: with no files named and none found, `test` and L2 fail.
      /// The ladder's columns line up, and a detail longer than its column is kept whole rather than cut off.
      @Test func ladderRowsPadButNeverTruncate() {
        #expect(
          Ladder.row(stage: "L2 scenarios", ok: true, detail: "21/21 scenarios", seconds: 0.4)
            == "L2 scenarios  ok    21/21 scenarios              0.4s"
        )
        let detail = "order-cancel via the app's agent bridge"
        #expect(
          Ladder.row(stage: "L4 app", ok: true, detail: detail, seconds: 12.34)
            == "L4 app        ok    \(detail) 12.3s"
        )
      }

      @Test func zeroScenariosFailTestAndTheLadder() async throws {
        AgentCtl.install(StubRuntime.restless)
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "scenarios"), withIntermediateDirectories: true)
        let code = await Self.withRepoRoot(root.path) {
          await serially { await Commands.test(paths: []) }
        }
        #expect(code == 3)
        #expect(Message.noScenarios(in: root.appending(path: "scenarios")).contains(root.path))
        let rungPassed = await serially { await Ladder(root: root).scenarios() }
        #expect(!rungPassed)
      }

      /// A scenario file that does not exist is a missing file (3), not a failed scenario (1).
      @Test func aMissingScenarioFileExitsThree() async {
        AgentCtl.install(StubRuntime.restless)
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).appctl")
        let code = await serially { await Commands.test(paths: [missing.path]) }
        #expect(code == 3)
      }

      /// No repo root is the same environment problem wherever it happens: 3 in `test`, as in `docs`.
      @Test func aMissingRepoRootExitsThree() async {
        AgentCtl.install(StubRuntime())
        // `StubApp.xcodeproj`, the stub's root marker, is above no directory a test runs in.
        let (test, docs) = await Self.withRepoRoot(nil) {
          (await serially { await Commands.test(paths: []) }, Commands.docs(check: true))
        }
        #expect(test == 3)
        #expect(docs == 3)
      }

      // MARK: - Helpers

      /// The error `AgentCtl.run(config:)` would see for `arguments`, without running any of the CLI's commands.
      /// `--help` parses to ArgumentParser's own synchronous help command, whose `run()` throws the help request.
      static func parseError(_ arguments: [String]) -> (any Error)? {
        do {
          var command = try AppCtlCommand.parseAsRoot(arguments)
          if !(command is any AsyncParsableCommand) {
            try command.run()
          }
          return nil
        } catch {
          return error
        }
      }

      static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentctl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
      }

      /// Runs `body` with `APPCTL_ROOT` set to `path`, or unset, and restores it afterwards.
      static func withRepoRoot<T>(_ path: String?, _ body: () async -> T) async -> T {
        let previous = ProcessInfo.processInfo.environment["APPCTL_ROOT"]
        if let path { setenv("APPCTL_ROOT", path, 1) } else { unsetenv("APPCTL_ROOT") }
        defer {
          if let previous { setenv("APPCTL_ROOT", previous, 1) } else { unsetenv("APPCTL_ROOT") }
        }
        return await body()
      }
    }
  }
#endif
