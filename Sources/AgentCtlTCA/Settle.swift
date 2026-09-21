import AgentCtlCore
import ComposableArchitecture
import Foundation

/// The outcome of waiting for the app to settle after a command.
public struct SettleResult: Equatable, Sendable {
  /// `false` when the real-time limit was reached before the app went quiet.
  public var settled: Bool
  /// Sleeps waiting on the clock (e.g. a countdown), from ``CountingClock/activeSleeps``. Headlessly, `advance`
  /// releases them.
  public var pending: Int

  public init(settled: Bool, pending: Int) {
    self.settled = settled
    self.pending = pending
  }
}

/// Headless settling, which is what lets a step be read only once the app has gone quiet (CONTRACT.md §6):
/// keep yielding until the state, the call log and the in-flight effect count
/// have not changed for `stableRounds` rounds, or until `limit` of real time has passed. `pending` reports the
/// sleeps waiting on the clock.
///
/// Must run with the main serial executor enabled, so that every task (including actor jobs) runs in order
/// on the main thread and yielding lets them all make progress.
///
/// `package` access, like ``settleLive``: a host settles through `HeadlessHost.settle()` and
/// `LiveHost.settle()`, which choose the thresholds.
@MainActor
package func settleHeadless<State: Equatable>(
  state: () -> State,
  callLog: MockCallLog,
  tracker: EffectTracker,
  pending: () -> Int,
  stableRounds: Int = 3,
  limit: Duration = .seconds(2)
) async -> SettleResult {
  func fingerprint() -> SettleFingerprint<State> {
    SettleFingerprint(state: state(), calls: callLog.count, inFlight: tracker.inFlight)
  }

  let realClock = ContinuousClock()
  let start = realClock.now
  var last = fingerprint()
  var stable = 0
  while stable < stableRounds {
    if start.duration(to: realClock.now) > limit {
      return SettleResult(settled: false, pending: pending())
    }
    await Task.megaYield()
    let next = fingerprint()
    if next == last {
      stable += 1
    } else {
      stable = 0
      last = next
    }
  }
  return SettleResult(settled: true, pending: pending())
}

private struct SettleFingerprint<State: Equatable>: Equatable {
  var state: State
  var calls: Int
  var inFlight: Int
}

/// Live settling for the running app: wait until no mock call is in flight and the state has not
/// changed for `quietWindow`, or until `limit`. Mock latency is real here, so this uses real time.
@MainActor
package func settleLive<State: Equatable>(
  state: () -> State,
  callLog: MockCallLog,
  pending: () -> Int,
  quietWindow: Duration = .milliseconds(100),
  pollInterval: Duration = .milliseconds(20),
  limit: Duration = .seconds(3)
) async -> SettleResult {
  let realClock = ContinuousClock()
  let start = realClock.now
  var last = state()
  var quietSince = realClock.now
  while start.duration(to: realClock.now) < limit {
    try? await realClock.sleep(for: pollInterval)
    let next = state()
    if next != last || callLog.inFlight > 0 {
      last = next
      quietSince = realClock.now
    } else if quietSince.duration(to: realClock.now) >= quietWindow {
      return SettleResult(settled: true, pending: pending())
    }
  }
  return SettleResult(settled: false, pending: pending())
}
