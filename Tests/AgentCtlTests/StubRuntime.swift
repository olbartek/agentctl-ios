#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation

  struct StubError: Error, CustomStringConvertible {
    var description = "connection refused"
  }

  /// A host for the CLI's tests.
  ///
  /// Its facts are fixed placeholders, and they must stay the same for every test: the CLI's `CommandConfiguration`s
  /// are `static let`s, built once per process from whichever runtime is installed first, so a test that installed
  /// a host with other facts could change the help pages another test reads. What varies is the app behind it —
  /// none by default, because the help tests never run a command, or the runner a command test supplies.
  final class StubRuntime: AppCtlRuntime {
    let name = "StubApp"
    let target = BuildTarget.project("StubApp.xcodeproj", scheme: "StubApp")
    let bundleID = "com.example.stub"
    let packages = ["Stub"]
    let snapshotPackages = ["Stub"]
    let simulatorName = "iPhone 17 Pro"
    let snapshotSimulatorName = "iPhone 17 Pro"
    let snapshotRuntimeMajor = 18
    let scenariosPath = "scenarios"
    let appCheck = AppCheck()
    let screens: [ScreenDoc] = []
    let mockMethods = [MockMethod("items.fetch", errorCodes: ["network"])]
    let docsText = DocsText(title: "Stub", intro: "", usageExamples: [], appendix: [])
    let help = HelpExamples(
      invocation: "xctl",
      note: "Always call it through the xctl wrapper.",
      runScripts: ["refresh; open 1", "refresh", "expect screen=items"],
      scenarioPath: "scenarios/browse.appctl",
      appSeeds: ["refresh", "refresh; open 1"],
      appScripts: ["open 1; expect id=1", "refresh"]
    )

    private let runner: @MainActor @Sendable () -> any ScriptRunning
    private let scenarios: @MainActor @Sendable ([URL]) async -> [ScenarioResult]

    init(
      runner: @escaping @MainActor @Sendable () -> any ScriptRunning = { StubRunner() },
      scenarios: @escaping @MainActor @Sendable ([URL]) async -> [ScenarioResult] = { _ in [] }
    ) {
      self.runner = runner
      self.scenarios = scenarios
    }

    /// The same host with ``Restless`` behind it: an app whose launch never settles.
    static var restless: StubRuntime {
      StubRuntime(
        runner: { Restless.makeRunner() },
        scenarios: { files in
          var results: [ScenarioResult] = []
          for file in files {
            results.append(await ScenarioRunner.run(file: file, make: { Restless.makeRunner() }))
          }
          return results
        }
      )
    }

    func clearSession() {}

    @MainActor
    func makeRunner() -> any ScriptRunning {
      runner()
    }

    @MainActor
    func runScenarios(_ files: [URL]) async -> [ScenarioResult] {
      await scenarios(files)
    }
  }

  /// The runner of a host with no app: enough to render help, never enough to run a script.
  @MainActor
  final class StubRunner: ScriptRunning {
    var recordsDiff = false
    let stateDump = "StubApp.State()"

    func launch() async -> (step: StepRecord, status: RunStatus) {
      (snapshot(command: "(launch)"), .ok)
    }

    func run(_ source: String) async -> RunResult {
      fatalError("the help tests never run a script")
    }

    func snapshot(command: String) -> StepRecord {
      StepRecord(command: command, screen: "items", summary: [], calls: [], error: nil, pending: 0)
    }
  }
#endif
