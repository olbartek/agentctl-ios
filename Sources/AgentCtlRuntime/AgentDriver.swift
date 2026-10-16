// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import Dependencies

  /// What the engine needs from an app, whatever its architecture. Everything else the runner does — parsing,
  /// `expect`, `advance`, `mock`, `device`, the step output, sessions — is the engine's own and never sees the app's
  /// types (CONTRACT.md holds for every driver).
  ///
  /// Two drivers ship: `AgentStoreDriver` (AgentCtlTCA) for an app built with the Composable Architecture, and
  /// `AgentObservationDriver` (AgentCtlObservation) for MVVM-C, `@Observable` view models under a coordinator.
  @MainActor
  public protocol AgentDriver: AnyObject {
    /// What a command, an appearance or a device event turns into. A value: commands produce it before it is sent,
    /// and the device configuration builds it without a reference to the running app, which a relaunch replaces.
    associatedtype Action: Sendable
    /// What headless settling compares, round after round. It must change whenever the app does anything a later
    /// round could depend on: a change of state, a unit of async work starting or finishing.
    associatedtype Fingerprint: Equatable
    /// The app's state as `--diff` compares it, before and after a step.
    associatedtype StateSnapshot
    /// What the app's root view shows: the TCA store, or the coordinator. `relaunch()` replaces it.
    associatedtype App

    var app: App { get }

    /// The screen an agent is looking at: path, identity, summary, error, appearance and commands.
    func activeScreen() -> ActiveScreen<Action>

    /// Delivers an action, synchronously. The work it starts is the app's, and settling waits for it.
    func send(_ action: Action)

    func fingerprint() -> Fingerprint

    /// Throws the app away, cancelling its work, and builds a fresh one from its initial state over the same
    /// dependencies: `device relaunch`.
    func relaunch()

    func stateSnapshot() -> StateSnapshot

    /// What changed since `before`, for `--diff`; `nil` when nothing did.
    func stateDiff(from before: StateSnapshot) -> String?

    /// The whole state, as `state` and `GET /state` print it.
    var stateDump: String { get }

    /// Called after ``relaunch()`` with the new ``app`` in place: the running app's shell shows it.
    var onRelaunch: (@MainActor () -> Void)? { get set }
  }
#endif
