import ComposableArchitecture

/// Counts effects that have started but not finished. Headless settling waits for this count to stop changing,
/// along with the state and the call log (see `settleHeadless`).
///
/// It is not the `pending` a step prints. An effect suspended on the clock stays counted here until the clock is
/// advanced far enough, but so do long-lived effects TCA starts for navigation, which `advance` would never
/// release. `pending` is ``CountingClock/activeSleeps`` instead: only the sleeps waiting on the clock.
@MainActor
public final class EffectTracker {
  public private(set) var inFlight = 0

  public init() {}

  func started() {
    inFlight += 1
  }

  func finished() {
    inFlight -= 1
  }
}

/// Wraps a reducer so that every effect it returns is counted by an ``EffectTracker``.
///
/// Uses only public API: the base effect is concatenated with a trailing effect that marks it finished.
/// A cancelled effect completes, so the trailing effect still runs.
public struct TrackingReducer<Base: Reducer>: Reducer where Base.Action: Sendable {
  let tracker: EffectTracker
  let base: Base

  public init(tracker: EffectTracker, base: Base) {
    self.tracker = tracker
    self.base = base
  }

  public func _reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
    let effect = base._reduce(into: &state, action: action)
    let tracker = tracker
    // `Store` runs reducers on the main thread.
    MainActor.assumeIsolated { tracker.started() }
    return .concatenate(effect, .run { _ in await tracker.finished() })
  }
}
