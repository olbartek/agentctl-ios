import AgentCtlCore
import AgentCtlTCA
import Foundation
import Synchronization
import Testing

/// What this guards: the running app's clock, which `advance` moves forward (issue #2). Sleeps end when the clock
/// reaches their deadline, however it got there; a timer fires once per interval advanced; cancelling still works.
///
/// What it does not guard: the app around it, which ``BridgeTests/advanceMovesTheRunningAppsClock`` covers.
@Suite
struct AdvanceableClockTests {
  /// A long sleep on a fresh clock, and the clock counting it, once it has started.
  func sleeping(_ duration: Duration) async throws -> (CountingClock<AdvanceableClock>, Task<Void, any Error>) {
    let clock = CountingClock(AdvanceableClock())
    let sleep = Task { try await clock.sleep(for: duration) }
    try await until { clock.activeSleeps == 1 }
    return (clock, sleep)
  }

  /// Polls `condition` for up to five seconds of real time.
  func until(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  @Test func advancingPastTheDeadlineEndsASleep() async throws {
    let (clock, sleep) = try await sleeping(.seconds(60))
    await clock.base.advance(by: .seconds(60))
    try await sleep.value
    #expect(clock.activeSleeps == 0)
    #expect(clock.base.offset >= .seconds(60))
  }

  @Test func advancingShortOfTheDeadlineDoesNot() async throws {
    let (clock, sleep) = try await sleeping(.seconds(60))
    await clock.base.advance(by: .seconds(30))
    try await Task.sleep(for: .milliseconds(100))
    #expect(clock.activeSleeps == 1)
    await clock.base.advance(by: .seconds(30))
    try await sleep.value
  }

  @Test func aTimerTicksOncePerIntervalAdvanced() async throws {
    let clock = CountingClock(AdvanceableClock())
    let ticks = Mutex(0)
    let timer = Task {
      for _ in 0..<5 {
        try await clock.sleep(for: .seconds(1))
        ticks.withLock { $0 += 1 }
      }
    }
    try await until { clock.activeSleeps == 1 }
    // Between deadlines, a moment for the loop to start its next sleep.
    await clock.base.advance(by: .seconds(3), between: { try? await Task.sleep(for: .milliseconds(20)) })
    #expect(ticks.withLock { $0 } == 3)
    timer.cancel()
  }

  @Test func aCancelledSleepThrows() async throws {
    let (_, sleep) = try await sleeping(.seconds(60))
    sleep.cancel()
    await #expect(throws: CancellationError.self) { try await sleep.value }
  }

  @Test func nowAndTheDateMoveWithTheClock() async {
    let clock = AdvanceableClock()
    let before = clock.now
    await clock.advance(by: .seconds(3600))
    #expect(before.duration(to: clock.now) >= .seconds(3600))
    #expect(clock.date().timeIntervalSinceNow > 3590)
  }
}
