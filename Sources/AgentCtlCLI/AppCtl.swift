#if os(macOS)
  import AgentCtlTCA
  import ArgumentParser
  import Foundation

  /// The `appctl` command tree. `AgentCtl.run(config:)` runs it; the host app's facts — including every example
  /// in the help text — come from `AgentCtl.runtime`, never from a literal here.
  struct AppCtlCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      // The name the CLI was invoked under, so a host's own executable (`tinyctl`) names itself in its help.
      // If there is no argv[0] at all, fall back to how the host spells the CLI in its examples.
      commandName: URL(fileURLWithPath: CommandLine.arguments.first ?? help.invocation).lastPathComponent,
      abstract: "Drive \(AgentCtl.runtime.name) headlessly, run its scenarios and check the verification ladder.",
      discussion: [help.note, "Command reference: \(AgentCtl.runtime.docsPath) (or \(help.invocation) screens)."]
        .compactMap { $0 }
        .joined(separator: "\n"),
      subcommands: [
        Run.self, StateCommand.self, Screens.self, Docs.self, Test.self, Snapshots.self, Check.self, AppCommand.self,
      ]
    )
  }

  struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run a script against a fresh headless app and print one step per command.",
      discussion: """
        Examples:
          \(help.invocation) run "\(help.runScript(0))"
          \(help.invocation) run --session \(help.sessionPath) "\(help.runScript(1))"
          \(help.invocation) run --json "\(help.runScript(2))"
        """
    )

    @Argument(help: "Commands separated by ';' or newlines. '#' starts a comment.")
    var script: String

    @Option(help: "Replay the commands saved in this file first, then append the new ones that succeed.")
    var session: String?

    @Flag(help: "Print a state diff after each step.")
    var diff = false

    @Flag(help: "Print a JSON array of steps instead of text.")
    var json = false

    func run() async throws {
      let code = await Commands.run(script: script, sessionPath: session, diff: diff, json: json)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct StateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "state",
      abstract: "Print the full root state (customDump) after replaying an optional session file.",
      discussion: """
        Examples:
          \(help.invocation) state
          \(help.invocation) state --session \(help.sessionPath)
        """
    )

    @Option(help: "Replay the commands saved in this file first.")
    var session: String?

    func run() async throws {
      let code = await Commands.state(sessionPath: session)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct Screens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List every screen path with its commands, arguments and help, including inherited commands."
    )

    func run() async throws {
      await Commands.screens()
    }
  }

  struct Docs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Write \(AgentCtl.runtime.docsPath) from the command registry.",
      discussion: """
        Examples:
          \(help.invocation) docs           # after changing any +Agent.swift
          \(help.invocation) docs --check   # exit 1 if the file is stale (part of \(help.invocation) check)
        """
    )

    @Flag(help: "Only check that the file is up to date; exit 1 if it is stale.")
    var check = false

    func run() async throws {
      let code = await Commands.docs(check: check)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run scenario files (default: \(AgentCtl.runtime.scenariosPath)/*.appctl) and print pass/fail per file.",
      discussion: """
        Examples:
          \(help.invocation) test
          \(help.invocation) test \(help.scenarioPath ?? "\(AgentCtl.runtime.scenariosPath)/<name>.appctl")
        """
    )

    @Argument(help: "Scenario files. Defaults to every \(AgentCtl.runtime.scenariosPath)/*.appctl.")
    var paths: [String] = []

    func run() async throws {
      let code = await Commands.test(paths: paths)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run the L3 view snapshot tests on an iOS \(AgentCtl.runtime.snapshotRuntimeMajor) simulator "
        + "(or re-record the reference images).",
      discussion: """
        Each screen is rendered in fixed states and compared with Packages/*/Tests/*SnapshotTests/__Snapshots__/.
        A failure prints the reference and actual image paths; look at both before deciding.
        Examples:
          \(help.invocation) snapshots             # after a view change (~45 s)
          \(help.invocation) snapshots --record    # after an intended visual change; review `git diff --stat` and the images
        """
    )

    @Flag(help: "Re-record every reference image instead of comparing.")
    var record = false

    @Option(help: "Simulator name or UDID (must run iOS \(AgentCtl.runtime.snapshotRuntimeMajor)).")
    var sim: String = AgentCtl.runtime.snapshotSimulatorName

    func run() async throws {
      let code = await Commands.snapshots(record: record, simulator: sim)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run the verification ladder: L0 build, L1 tests, L2 scenarios, docs check (--ui adds L3 and L4).",
      discussion: """
        Prints one line per stage and stops at the first failing stage. Full logs: .appctl/logs/.
        Examples:
          \(help.invocation) check          # before every commit (~1 min)
          \(help.invocation) check --ui     # also L3 view snapshots and L4: the app on a simulator, a scenario via AgentBridge
        """
    )

    @Flag(
      help: ArgumentHelp(
        "Add L3 (view snapshots on an iOS \(AgentCtl.runtime.snapshotRuntimeMajor) simulator) and L4 "
          + "(seeded app, a scenario through AgentBridge, a screenshot)."
      )
    )
    var ui = false

    @Option(help: "Simulator name or UDID for --ui.")
    var sim: String = AgentCtl.runtime.simulatorName

    func run() async throws {
      let code = await Commands.check(ui: ui, simulator: sim)
      if code != 0 { throw ExitCode(code) }
    }
  }

  /// `appctl app …`: the same commands, sent to the running app through AgentBridge.
  struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "app",
      abstract: "Launch the app on a simulator and drive it through AgentBridge.",
      subcommands: [AppLaunch.self, AppRun.self, AppState.self, AppScreens.self]
    )
  }

  struct BridgeOptions: ParsableArguments {
    @Option(help: "AgentBridge port (the app's -agent-port).")
    var port: Int = 8765
  }

  struct AppLaunch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "launch",
      abstract: "Build and run the app on a simulator, optionally already in a seeded state.",
      discussion: """
        Examples:
          \(help.invocation) app launch --seed "\(help.appSeed(0))"
          \(help.invocation) app launch --no-build --seed "\(help.appSeed(1))"
        """
    )

    @Option(help: "Commands to run before the first frame (-appctl-seed).")
    var seed: String?

    @Option(help: "Simulator name or UDID.")
    var sim: String = AgentCtl.runtime.simulatorName

    @Option(help: "Fixed mock latency in ms (default: the app's 300–800 ms).")
    var latency: Int?

    @Flag(help: "Forget the saved session before launching.")
    var clearSession = false

    @Flag(help: "Relaunch the installed app instead of building it.")
    var noBuild = false

    @OptionGroup var bridge: BridgeOptions

    func run() async throws {
      let code = await AppCommands.launch(
        seed: seed, simulator: sim, latency: latency, clearSession: clearSession, build: !noBuild, port: bridge.port
      )
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct AppRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Run a script in the running app (headless-only commands such as advance are rejected).",
      discussion: """
        Examples:
          \(help.invocation) app run "\(help.appScript(0))"
          \(help.invocation) app run --json "\(help.appScript(1))"
        """
    )

    @Argument(help: "Commands separated by ';' or newlines.")
    var script: String

    @Flag(help: "Print a JSON array of steps.")
    var json = false

    @OptionGroup var bridge: BridgeOptions

    func run() async throws {
      let code = await AppCommands.run(script: script, json: json, port: bridge.port)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct AppState: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "state",
      abstract: "Print the running app's root state.",
      discussion: "Example: \(help.invocation) app state --port 8765"
    )

    @OptionGroup var bridge: BridgeOptions

    func run() async throws {
      let code = await AppCommands.get("/state", port: bridge.port)
      if code != 0 { throw ExitCode(code) }
    }
  }

  struct AppScreens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "screens", abstract: "List screens, from the running app.")

    @OptionGroup var bridge: BridgeOptions

    func run() async throws {
      let code = await AppCommands.get("/screens", port: bridge.port)
      if code != 0 { throw ExitCode(code) }
    }
  }
#endif
