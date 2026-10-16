#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import ArgumentParser
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: the exit codes of `snapshots`, `check`, `--session` files and a command group run without
    /// a subcommand (CONTRACT.md §5) — 1 only when something ran and found the app wrong, 2 for a malformed command
    /// line, 3 when it could not run at all. agentctl-android classifies the same paths the same way.
    ///
    /// Nothing here touches a simulator: a fake `simctl` plays the simulators, as in ``SimulatorChoiceTests``.
    @MainActor
    @Suite struct CLIExitStatusTests {
      typealias Fake = SimulatorChoiceTests.Fake

      // MARK: - k: no subcommand

      /// `appctl` or `appctl app` alone is a malformed command line: its help goes to stderr with exit 2. Asked
      /// for, with `--help`, `-h` or `help`, it is not a group run without a subcommand, and keeps exit 0.
      @Test func aGroupWithoutASubcommandIsAUsageError() throws {
        AgentCtl.install(StubRuntime())
        for arguments in [[], ["app"], ["app", "record"], ["app", "statusbar"]] {
          let command = try AppCtlCommand.parseAsRoot(arguments)
          let usage = try #require(AgentCtl.missingSubcommand(command), "\(arguments)")
          #expect(usage.contains("USAGE: "), "\(arguments)")
          #expect(usage.contains("SUBCOMMANDS:"), "\(arguments)")
        }
        for arguments in [["run", "refresh"], ["app", "record", "stop"], ["app", "statusbar", "clean"]] {
          #expect(AgentCtl.missingSubcommand(try AppCtlCommand.parseAsRoot(arguments)) == nil, "\(arguments)")
        }
        for arguments in [["--help"], ["-h"], ["help"], ["help", "app"], ["app", "--help"], ["app", "record", "-h"]] {
          let error = CLICommandTests.parseError(arguments)
          #expect(error.map(AgentCtl.exitStatus(for:)) == 0, "\(arguments)")
        }
      }

      // MARK: - j: --session files

      /// No file yet is an empty session, created by the first run, directories and all.
      @Test func aMissingSessionFileIsAnEmptySession() throws {
        let directory = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "new/sub/session.txt").path
        #expect(try Session.load(path) == "")
        #expect(Session.write([ScriptLine(line: 1, name: "refresh", argument: nil)], to: path))
        #expect(Session.write([ScriptLine(line: 1, name: "open", argument: "1")], to: path))
        #expect(try Session.load(path) == "refresh\nopen 1\n")
        let empty = directory.appending(path: "empty.txt").path
        #expect(Session.write([], to: empty))
        #expect(FileManager.default.fileExists(atPath: empty))
      }

      /// A session file that exists but cannot be read — a directory, or one without read permission — exits 3
      /// before any line of it runs, for `run` and `state` alike.
      @Test func anUnreadableSessionFileExitsThree() async throws {
        AgentCtl.install(StubRuntime())
        let directory = try CLICommandTests.temporaryDirectory()
        defer {
          try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appending(path: "locked").path)
          try? FileManager.default.removeItem(at: directory)
        }
        let locked = directory.appending(path: "locked")
        try "refresh\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        for (path, reason) in [(directory.path, "Is a directory"), (locked.path, "Permission denied")] {
          let error = #expect(throws: (any Error).self, "\(path)") { try Session.load(path) }
          // The bare reason, never the path: the message names the path as given once, before it.
          #expect(error.map(Session.reason) == reason, "\(path)")
          #expect(Session.read(path) == nil, "\(path)")
          let run = await serially { await Commands.run(script: "refresh", sessionPath: path, diff: false, json: false) }
          let state = await serially { await Commands.state(sessionPath: path) }
          #expect(run == 3, "\(path)")
          #expect(state == 3, "\(path)")
        }
      }

      /// A session file that cannot be written is an error, not a run silently left unsaved.
      @Test func anUnwritableSessionFileIsAWriteError() throws {
        let directory = try CLICommandTests.temporaryDirectory()
        let readOnly = directory.appending(path: "read-only.txt")
        defer {
          try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnly.path)
          try? FileManager.default.removeItem(at: directory)
        }
        try "refresh\n".write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        #expect(!Session.write([ScriptLine(line: 1, name: "open", argument: "1")], to: readOnly.path))
        let error = #expect(throws: (any Error).self) {
          try Session.append([ScriptLine(line: 1, name: "open", argument: "1")], to: readOnly.path)
        }
        #expect(error.map(Session.reason) == "Permission denied")
        #expect(try Session.load(readOnly.path) == "refresh\n")
      }

      // MARK: - d: snapshots

      /// Nothing configured: nothing to compare passes, nothing to record cannot run (3). No simulator is needed.
      @Test func snapshotsWithNothingConfigured() {
        AgentCtl.install(StubRuntime())
        let root = URL(fileURLWithPath: "/nonexistent")
        let verify = SnapshotRunner.run(root: root, simulator: "iPhone 17 Pro", record: false, packages: [])
        #expect(verify.status == .ok)
        let record = SnapshotRunner.run(root: root, simulator: "iPhone 17 Pro", record: true, packages: [])
        #expect(record.status == .internalError)
        #expect(record.details == ["nothing to record: no package (the config's snapshotPackages is empty)"])
      }

      /// No simulator for the runtime is an environment failure (3); several that could be meant is a usage
      /// error (2), as `app launch` says for the same `--sim`.
      @Test func snapshotsThatCannotChooseASimulator() throws {
        AgentCtl.install(StubRuntime())
        let directory = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let packages = ["Modules/Features/StubFeature"]
        func status(_ devices: [Fake]) throws -> RunStatus {
          let tool = try SimulatorChoiceTests.fakeSimctl(devices, in: directory)
          return Simulator.$simctl.withValue([tool.path]) {
            SnapshotRunner.run(root: directory, simulator: "iPhone 16 Pro", record: false, packages: packages).status
          }
        }
        // The stub's snapshot runtime is iOS 18.
        #expect(try status([Fake(id: 1, runtime: "26.5")]) == .internalError)
        #expect(try status([Fake(id: 1, runtime: "18.6"), Fake(id: 2, runtime: "18.6")]) == .usage)
        // A package with no snapshot tests is a configuration problem the run cannot get past (3).
        #expect(try status([Fake(id: 1, runtime: "18.6")]) == .internalError)
      }

      // MARK: - d: check

      /// A build or test that ran and failed is the rung's verdict (1); a tool that could not start or was stopped
      /// means the rung could not run (3).
      @Test func aRungsToolStatus() {
        #expect(Ladder.rungStatus(0) == .ok)
        #expect(Ladder.rungStatus(1) == .failed)
        #expect(Ladder.rungStatus(65) == .failed)
        #expect(Ladder.rungStatus(-1) == .internalError)
        #expect(Ladder.rungStatus(Shell.timedOut) == .internalError)
      }

      /// L4's configured scenario is looked for before anything is built: a name with no file is a missing file (3).
      @Test func l4sConfiguredScenarioMustExist() throws {
        let directory = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "open 1\n".write(to: directory.appending(path: "browse.appctl"), atomically: true, encoding: .utf8)
        #expect(Ladder.missingScenario(nil, in: directory) == nil)
        #expect(Ladder.missingScenario("browse", in: directory) == nil)
        #expect(Ladder.missingScenario("checkout", in: directory) == directory.appending(path: "checkout.appctl"))
      }
    }
  }
#endif
