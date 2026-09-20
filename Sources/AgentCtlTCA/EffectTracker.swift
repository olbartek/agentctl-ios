import AgentCtlCore
import ComposableArchitecture

/// Counts effects that have started but not finished. The count is `pending` in step summaries.
///
/// Effects suspended on a `TestClock` stay counted until the clock is advanced far enough, which is how
/// `appctl` reports a running countdown as `pending=1`.
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
