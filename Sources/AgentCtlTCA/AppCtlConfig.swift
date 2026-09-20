import AgentCtlCore
import ComposableArchitecture
import Foundation

/// How `xcodebuild` is invoked for this app.
public enum BuildTarget: Sendable {
  case workspace(String, scheme: String)
  case project(String, scheme: String)

  /// The `.xcworkspace` or `.xcodeproj`, relative to the repo root. Its presence marks the repo root.
  public var path: String {
    switch self {
    case let .workspace(path, _), let .project(path, _): path
    }
  }

  public var scheme: String {
    switch self {
    case let .workspace(_, scheme), let .project(_, scheme): scheme
    }
  }

  public var xcodebuildArguments: [String] {
    switch self {
    case let .workspace(path, scheme): ["-workspace", path, "-scheme", scheme]
    case let .project(path, scheme): ["-project", path, "-scheme", scheme]
    }
  }
}

/// L4 of `check --ui`: the app is launched on a simulator, seeded, then one scenario runs through AgentBridge.
public struct AppCheck: Sendable {
  /// Commands to seed the app with before the scenario (`-appctl-seed`).
  public var seed: String?
  /// The scenario to send through the bridge, without its extension. `nil` uses the first scenario file.
  public var scenario: String?
  /// The screen path the app must be on afterwards, e.g. `<area>/<screen>`. `nil` skips that assertion.
  public var expectScreen: String?

  public init(seed: String? = nil, scenario: String? = nil, expectScreen: String? = nil) {
    self.seed = seed
    self.scenario = scenario
    self.expectScreen = expectScreen
  }
}

/// The example commands printed in the CLI's help pages.
///
/// The defaults are placeholders (`<command>`, `<path>`) that hold for every host, so a published CLI never
/// advertises another app's screens. A host that fills them in gets help written in its own vocabulary; the
/// flags, subcommand names and abstracts are the same either way.
public struct HelpExamples: Sendable {
  /// How the examples spell the CLI, e.g. `./appctl` for a repo whose wrapper script rebuilds it first.
  /// Defaults to the executable's own name, as it was invoked.
  public var invocation: String
  /// An extra paragraph for the top-level help, printed above the command reference — for instance how the
  /// host's wrapper should be called. `nil` prints none.
  public var note: String?
  /// The scripts in the three `run` examples: a plain run, a `--session` run, and a `--json` run.
  public var runScripts: [String]
  /// The `--session` file in the `run` and `state` examples.
  public var sessionPath: String
  /// The scenario file in the `test` example. `nil` uses `<scenariosPath>/<name>.appctl`.
  public var scenarioPath: String?
  /// The seeds in the two `app launch` examples: a plain seed, and one for `--no-build`.
  public var appSeeds: [String]
  /// The scripts in the two `app run` examples: a plain run, and a `--json` run.
  public var appScripts: [String]

  public init(
    invocation: String = HelpExamples.defaultInvocation,
    note: String? = nil,
    runScripts: [String] = ["<command>; <command>", "<command>", "expect screen=<path>"],
    sessionPath: String = ".appctl/s1.session",
    scenarioPath: String? = nil,
    appSeeds: [String] = ["<command>", "<command>; <command>"],
    appScripts: [String] = ["<command>; expect <key>=<value>", "<command>"]
  ) {
    self.invocation = invocation
    self.note = note
    self.runScripts = runScripts
    self.sessionPath = sessionPath
    self.scenarioPath = scenarioPath
    self.appSeeds = appSeeds
    self.appScripts = appScripts
  }

  /// The name the CLI was invoked under, so a host's own executable (`tinyctl`) names itself in its examples.
  /// The same rule as ``DocsText/invocation``'s default, so help and docs agree.
  public static var defaultInvocation: String {
    CLIName.current
  }

  /// The `run` script at `index`, or a placeholder if the host supplied fewer examples.
  public func runScript(_ index: Int) -> String {
    Self.element(runScripts, index)
  }

  /// The `app launch --seed` value at `index`, or a placeholder.
  public func appSeed(_ index: Int) -> String {
    Self.element(appSeeds, index)
  }

  /// The `app run` script at `index`, or a placeholder.
  public func appScript(_ index: Int) -> String {
    Self.element(appScripts, index)
  }

  private static func element(_ examples: [String], _ index: Int) -> String {
    index < examples.count ? examples[index] : "<command>"
  }
}

/// Everything AgentCtl needs to know about a host app: the facts the CLI would otherwise hard-code, the data
/// the docs are rendered from, and the closures that build the app's stores.
public struct AppCtlConfig<Root: Reducer & AgentContainer>: Sendable
where
  Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  /// The app's name, as it appears in the CLI's help.
  public var name: String
  public var target: BuildTarget
  /// The file or directory whose presence marks the repo root, relative to it. `nil` uses ``target``'s path,
  /// which is what an app with an Xcode project wants: the `.xcworkspace` or `.xcodeproj` sits at the root.
  ///
  /// A host with nothing to build — a package driven headlessly, say — names a file that really is at its root
  /// (`Package.swift`) instead of pointing ``target`` at something that does not exist. The root is where
  /// ``scenariosPath`` and ``docsPath`` are resolved from.
  public var rootMarker: String?
  public var bundleID: String
  /// SwiftPM packages built and tested by `check` (L0, L1).
  public var packages: [String]
  /// Packages whose `*SnapshotTests` run in `snapshots` (L3).
  public var snapshotPackages: [String]
  /// The simulator `app launch` and `check --ui` use by default.
  public var simulatorName: String
  /// The simulator the L3 reference images were recorded on.
  public var snapshotSimulatorName: String
  /// The iOS major version L3 needs, e.g. 18.
  public var snapshotRuntimeMajor: Int
  /// Where `test` and `check` look for `*.appctl` files, relative to the repo root.
  public var scenariosPath: String
  /// Where `docs` writes the generated command reference, relative to the repo root. A host whose app is not at
  /// the root of its repository — an example inside a package, say — points this inside the app's own directory,
  /// so the file lives next to the app it documents.
  public var docsPath: String
  public var appCheck: AppCheck
  /// The example commands in the CLI's help pages.
  public var help: HelpExamples
  public var mockMethods: [MockMethod]
  public var docsText: DocsText
  public var screens: [ScreenDoc]
  public var makeHeadless: @MainActor @Sendable () -> HeadlessHost<Root>
  /// The app's store for AgentBridge (real clock, real mock latency).
  public var makeLive: @MainActor @Sendable (MockLatency) -> LiveHost<Root>
  /// Called for `-clear-session` before the app launches.
  public var clearSession: @Sendable () -> Void

  /// - Parameters:
  ///   - snapshotPackages: defaults to `packages`.
  ///   - snapshotSimulatorName: defaults to `simulatorName`.
  ///   - rootMarker: defaults to `target`'s path.
  public init(
    name: String,
    target: BuildTarget,
    rootMarker: String? = nil,
    bundleID: String,
    packages: [String],
    snapshotPackages: [String]? = nil,
    simulatorName: String,
    snapshotSimulatorName: String? = nil,
    snapshotRuntimeMajor: Int,
    scenariosPath: String = "scenarios",
    docsPath: String = "docs/agent-commands.md",
    appCheck: AppCheck = AppCheck(),
    help: HelpExamples = HelpExamples(),
    mockMethods: [MockMethod],
    docsText: DocsText,
    screens: [ScreenDoc],
    makeHeadless: @escaping @MainActor @Sendable () -> HeadlessHost<Root>,
    makeLive: @escaping @MainActor @Sendable (MockLatency) -> LiveHost<Root>,
    clearSession: @escaping @Sendable () -> Void
  ) {
    self.name = name
    self.target = target
    self.rootMarker = rootMarker
    self.bundleID = bundleID
    self.packages = packages
    self.snapshotPackages = snapshotPackages ?? packages
    self.simulatorName = simulatorName
    self.snapshotSimulatorName = snapshotSimulatorName ?? simulatorName
    self.snapshotRuntimeMajor = snapshotRuntimeMajor
    self.scenariosPath = scenariosPath
    self.docsPath = docsPath
    self.appCheck = appCheck
    self.help = help
    self.mockMethods = mockMethods
    self.docsText = docsText
    self.screens = screens
    self.makeHeadless = makeHeadless
    self.makeLive = makeLive
    self.clearSession = clearSession
  }
}

/// The non-generic face of an ``AppCtlConfig``, for a CLI whose command types are static and cannot name the
/// root reducer.
///
/// The facts are `nonisolated` on purpose: ArgumentParser builds `CommandConfiguration`s and option defaults
/// outside any actor, and the simulator helpers are plain structs. Everything that touches a store is
/// `@MainActor`.
public protocol AppCtlRuntime: AnyObject, Sendable {
  var name: String { get }
  var target: BuildTarget { get }
  /// What the CLI walks up the directory tree for to find the repo root. Defaults to ``target``'s path.
  var rootMarker: String { get }
  var bundleID: String { get }
  var packages: [String] { get }
  var snapshotPackages: [String] { get }
  var simulatorName: String { get }
  var snapshotSimulatorName: String { get }
  var snapshotRuntimeMajor: Int { get }
  var scenariosPath: String { get }
  /// Where the generated command reference is written, relative to the repo root.
  var docsPath: String { get }
  var appCheck: AppCheck { get }
  var help: HelpExamples { get }
  var screens: [ScreenDoc] { get }
  var mockMethods: [MockMethod] { get }
  var docsText: DocsText { get }
  func clearSession()
  /// A fresh deterministic headless runner.
  @MainActor func makeRunner() -> any ScriptRunning
  /// Runs each scenario file against its own fresh runner.
  @MainActor func runScenarios(_ files: [URL]) async -> [ScenarioResult]
}

extension AppCtlRuntime {
  /// An app with an Xcode project is marked by it, so a host that sets no marker of its own needs no code.
  public var rootMarker: String { target.path }
  /// Where an app at the root of its own repository keeps its generated command reference.
  public var docsPath: String { "docs/agent-commands.md" }
}

/// What the CLI does with a runner, without naming the root reducer.
@MainActor
public protocol ScriptRunning: AnyObject {
  var recordsDiff: Bool { get set }
  var stateDump: String { get }
  func launch() async -> StepRecord
  func run(_ source: String) async -> RunResult
  func snapshot(command: String) -> StepRecord
}

extension ScriptRunner: ScriptRunning {}

/// Holds a typed ``AppCtlConfig`` behind ``AppCtlRuntime``: the one place the root reducer's type is erased.
public final class ErasedConfig<Root: Reducer & AgentContainer>: AppCtlRuntime
where
  Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  let config: AppCtlConfig<Root>

  public init(config: AppCtlConfig<Root>) {
    self.config = config
  }

  public var name: String { config.name }
  public var target: BuildTarget { config.target }
  public var rootMarker: String { config.rootMarker ?? config.target.path }
  public var bundleID: String { config.bundleID }
  public var packages: [String] { config.packages }
  public var snapshotPackages: [String] { config.snapshotPackages }
  public var simulatorName: String { config.simulatorName }
  public var snapshotSimulatorName: String { config.snapshotSimulatorName }
  public var snapshotRuntimeMajor: Int { config.snapshotRuntimeMajor }
  public var scenariosPath: String { config.scenariosPath }
  public var docsPath: String { config.docsPath }
  public var appCheck: AppCheck { config.appCheck }
  public var help: HelpExamples { config.help }
  public var screens: [ScreenDoc] { config.screens }
  public var mockMethods: [MockMethod] { config.mockMethods }
  public var docsText: DocsText { config.docsText }

  public func clearSession() {
    config.clearSession()
  }

  @MainActor
  public func makeRunner() -> any ScriptRunning {
    config.makeHeadless().makeRunner()
  }

  @MainActor
  public func runScenarios(_ files: [URL]) async -> [ScenarioResult] {
    var results: [ScenarioResult] = []
    for file in files {
      results.append(await ScenarioRunner.run(file: file, make: { [config] in config.makeHeadless().makeRunner() }))
    }
    return results
  }
}
