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
    // A minute per tick: the clock also runs in real time, and with a one-second interval a loaded full suite could
    // take a real second and see a fourth tick come due by itself.
    let timer = Task {
      for _ in 0..<5 {
        try await clock.sleep(for: .seconds(60))
        // A tick that takes a while, as on a loaded CI runner or in a real app: longer than a fixed wait between
        // deadlines would have allowed.
        try await Task.sleep(for: .milliseconds(50))
        ticks.withLock { $0 += 1 }
      }
    }
    try await until { clock.base.registeredSleeps == 1 }
    // Between deadlines, the app settles: here, until the timer has ticked for the deadline just passed and its next
    // sleep is one `advance` sees. A fixed 20 ms wait raced (it failed on the Kotlin port's CI): when the timer had
    // not started its next sleep yet, `advance` found nothing due and jumped to the end, ticking once instead of three
    // times.
    let deadlines = Mutex(0)
    await clock.base.advance(
      by: .seconds(180),
      between: {
        let passed = deadlines.withLock { $0 += 1; return min($0, 3) }
        try? await until { ticks.withLock { $0 } >= passed && clock.base.registeredSleeps == 1 }
      })
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
