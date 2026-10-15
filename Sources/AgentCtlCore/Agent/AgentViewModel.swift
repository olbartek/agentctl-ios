/// What a command, an appearance or a device event does to an MVVM-C app: a closure over its coordinator. A value,
/// so the device configuration can build one without a reference to the running app, which a relaunch replaces.
public struct AppIntent<App: AnyObject>: Sendable {
  public let run: @MainActor @Sendable (App) -> Void

  public init(_ run: @escaping @MainActor @Sendable (App) -> Void) {
    self.run = run
  }
}

/// A screen's command in an MVVM-C app: a closure over its own view model. ``AgentViewModel/activeScreen(as:)``
/// binds it to the instance on screen and lifts it to the app's ``AppIntent``.
public struct ScreenIntent<ViewModel: AnyObject>: Sendable {
  public let run: @MainActor @Sendable (ViewModel) -> Void

  public init(_ run: @escaping @MainActor @Sendable (ViewModel) -> Void) {
    self.run = run
  }
}

/// A screen of an MVVM-C app: an `@Observable` view model. Its agent surface is ``AgentScreen`` unchanged — path,
/// summary, error, gates and commands are functions of a value, ``agentState``, exactly as a TCA screen's are of its
/// `State` — so the command builders, gates and docs are shared. Its commands are ``ScreenIntent``s.
///
/// The `AgentScreen` requirements are static and `nonisolated`; ``agentState`` is read on the main actor, cheaply,
/// on every settling round.
@MainActor
public protocol AgentViewModel: AnyObject, Sendable, AgentScreen where AgentAction == ScreenIntent<Self> {
  /// The values the summary, the error and the gates read.
  var agentState: AgentState { get }
}

extension AgentViewModel {
  /// This screen, with its intents bound to this instance and lifted to the app's.
  public func activeScreen<App: AnyObject>(as _: App.Type = App.self) -> ActiveScreen<AppIntent<App>> {
    Self.activeScreen(agentState).map { intent in AppIntent { _ in intent.run(self) } }
  }
}

/// The root of an MVVM-C app: the coordinator, which owns navigation, resolves the screen an agent is looking at
/// (what `AgentContainer` does for a TCA root, on an instance), and can cancel everything the app is doing.
///
/// The rules that keep it deterministic, as TCA's store keeps a reducer: view models are `@MainActor`; every clock,
/// date, UUID and client comes from `@Dependency`; async work starts through ``AgentTasks`` (`\.agentTasks`);
/// child view models are created with `withDependencies(from: self)`; a pop cancels the popped screen's work; stack
/// ids are a counter, not `UUID()`.
@MainActor
public protocol AgentCoordinator: AnyObject, Sendable {
  /// The screen on top, with the coordinator's own commands (`back`) appended.
  func activeScreen() -> ActiveScreen<AppIntent<Self>>
  /// Cancels the work of every view model it holds: a relaunch throws the app away.
  func cancelAllWork()
  /// What `state` prints. The default names the type only.
  var agentStateDump: String { get }
}

extension AgentCoordinator {
  public var agentStateDump: String { "\(Self.self)" }
}
