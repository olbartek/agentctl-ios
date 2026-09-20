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
  /// The screen the app must be on afterwards, e.g. `home/orders`. `nil` skips that assertion.
  public var expectScreen: String?

  public init(seed: String? = nil, scenario: String? = nil, expectScreen: String? = nil) {
    self.seed = seed
    self.scenario = scenario
    self.expectScreen = expectScreen
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
  public var appCheck: AppCheck
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
  public init(
    name: String,
    target: BuildTarget,
    bundleID: String,
    packages: [String],
    snapshotPackages: [String]? = nil,
    simulatorName: String,
    snapshotSimulatorName: String? = nil,
    snapshotRuntimeMajor: Int,
    scenariosPath: String = "scenarios",
    appCheck: AppCheck = AppCheck(),
    mockMethods: [MockMethod],
    docsText: DocsText,
    screens: [ScreenDoc],
    makeHeadless: @escaping @MainActor @Sendable () -> HeadlessHost<Root>,
    makeLive: @escaping @MainActor @Sendable (MockLatency) -> LiveHost<Root>,
    clearSession: @escaping @Sendable () -> Void
  ) {
    self.name = name
    self.target = target
    self.bundleID = bundleID
    self.packages = packages
    self.snapshotPackages = snapshotPackages ?? packages
    self.simulatorName = simulatorName
    self.snapshotSimulatorName = snapshotSimulatorName ?? simulatorName
    self.snapshotRuntimeMajor = snapshotRuntimeMajor
    self.scenariosPath = scenariosPath
    self.appCheck = appCheck
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
  var bundleID: String { get }
  var packages: [String] { get }
  var snapshotPackages: [String] { get }
  var simulatorName: String { get }
  var snapshotSimulatorName: String { get }
  var snapshotRuntimeMajor: Int { get }
  var scenariosPath: String { get }
  var appCheck: AppCheck { get }
  var screens: [ScreenDoc] { get }
  var mockMethods: [MockMethod] { get }
  var docsText: DocsText { get }
  func clearSession()
  /// A fresh deterministic headless runner.
  @MainActor func makeRunner() -> any ScriptRunning
  /// Runs each scenario file against its own fresh runner.
  @MainActor func runScenarios(_ files: [URL]) async -> [ScenarioResult]
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
  public var bundleID: String { config.bundleID }
  public var packages: [String] { config.packages }
  public var snapshotPackages: [String] { config.snapshotPackages }
  public var simulatorName: String { config.simulatorName }
  public var snapshotSimulatorName: String { config.snapshotSimulatorName }
  public var snapshotRuntimeMajor: Int { config.snapshotRuntimeMajor }
  public var scenariosPath: String { config.scenariosPath }
  public var appCheck: AppCheck { config.appCheck }
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
