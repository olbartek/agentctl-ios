import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation

/// The smallest app whose `(launch)` step never settles: its one screen, on appearing, starts an effect that keeps
/// changing the state for longer than the runner waits for quiet — what a real-time dependency leaking into a
/// headless run looks like. The fixture for the rule that a `settled=false` step fails (CONTRACT.md §3.1, §5), at
/// launch as anywhere else.
@Reducer
struct Restless {
  /// How long ``makeRunner()``'s settling waits: a tenth of the headless host's two seconds, to keep tests fast.
  static let settleLimit: Duration = .milliseconds(100)
  /// How long the effect keeps the state changing: longer than ``settleLimit``, and finite, so it ends by itself
  /// soon after the test that started it.
  static let busyFor: Duration = .milliseconds(500)

  @ObservableState
  struct State: Equatable {
    var ticks = 0
  }

  enum Action: Sendable {
    case appeared
    case tick
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        return .run { send in
          let clock = ContinuousClock()
          let deadline = clock.now.advanced(by: Restless.busyFor)
          while clock.now < deadline, !Task.isCancelled {
            await send(.tick)
          }
        }
      case .tick:
        state.ticks += 1
        return .none
      }
    }
  }
}

extension Restless: AgentScreen, AgentContainer {
  static let screenPaths = ["restless"]
  static func screenPath(_ state: State) -> String { "restless" }
  // No summary: the tick count depends on the machine's speed, and a step must not print it.
  static let summaryKeys: [String] = []
  static func summary(_ state: State) -> [SummaryItem] { [] }
  static let onAppear: Action? = .appeared
  static let commands: [AgentCommand<State, Action>] = []
  static var registry: [ScreenDoc] { screenDocs }

  /// A headless runner on a fresh store, settling as `HeadlessHost` does but giving up after ``settleLimit``.
  /// Run it with the main serial executor (`serially`).
  @MainActor
  static func makeRunner() -> ScriptRunner<Restless> {
    let callLog = MockCallLog()
    let tracker = EffectTracker()
    let store = Store(initialState: State()) {
      TrackingReducer(tracker: tracker, base: Restless())
    }
    return ScriptRunner(
      store: store,
      callLog: callLog,
      faults: MockFaults(),
      tracker: tracker,
      pending: { 0 },
      environment: RunnerEnvironment(
        settle: {
          await settleHeadless(
            state: { store.state }, callLog: callLog, tracker: tracker, pending: { 0 }, limit: settleLimit
          )
        },
        advance: nil,
        synthesizesAppearance: true
      ),
      mockMethods: []
    )
  }
}
