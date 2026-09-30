import AgentCtlCore
import AgentCtlTCA
import Foundation
import Testing

extension AgentCtlSuite {
  /// What this guards: a live step settles only once the app's UI is at rest (CONTRACT.md §8.5). A command sent while
  /// a navigation transition still animates can be lost, so a busy UI holds settling like a changing state does, and
  /// one that stays busy past the ceiling does not settle.
  @MainActor
  @Suite struct LiveSettleTests {
    @Test func aBusyUIHoldsSettlingUntilItIsIdle() async {
      let clock = ContinuousClock()
      let start = clock.now
      let busyFor = Duration.milliseconds(300)
      let result = await settleLive(
        state: { 0 },
        callLog: MockCallLog(),
        pending: { 0 },
        isUIIdle: { start.duration(to: clock.now) >= busyFor },
        quietWindow: .milliseconds(100)
      )
      let elapsed = start.duration(to: clock.now)
      #expect(result.settled)
      // Idle after 300 ms, then quiet for the window, counted from the last busy poll (20 ms apart): well past the
      // 300 ms, where a quiet state alone would settle after about 100 ms.
      #expect(elapsed >= .milliseconds(370), "settled after \(elapsed)")
    }

    /// Within the ceiling, a UI that is still busy (a transition longer than it) does not settle.
    @Test func aUIStillBusyAtTheCeilingDoesNotSettle() async {
      let result = await settleLive(
        state: { 0 },
        callLog: MockCallLog(),
        pending: { 0 },
        isUIIdle: { false },
        quietWindow: .milliseconds(50),
        limit: .milliseconds(300)
      )
      #expect(!result.settled)
    }

    /// An endless animation (a spinner) is busy with short idle gaps between frames. After a second at a stretch it
    /// stops holding settling, so a screen with a spinner still settles.
    @Test func anEndlessAnimationStopsHoldingAfterASecond() async {
      let clock = ContinuousClock()
      let start = clock.now
      var polls = 0
      let result = await settleLive(
        state: { 0 },
        callLog: MockCallLog(),
        pending: { 0 },
        isUIIdle: {
          polls += 1
          return polls % 3 == 0  // idle for one poll in three: gaps of 20 ms, shorter than a stretch's 100 ms
        },
        quietWindow: .milliseconds(100)
      )
      let elapsed = start.duration(to: clock.now)
      #expect(result.settled)
      #expect(elapsed >= .milliseconds(1000), "settled after \(elapsed)")
      #expect(elapsed < .milliseconds(2000), "settled after \(elapsed)")
    }

    @Test func withoutAUICheckTheQuietStateIsEnough() async {
      let clock = ContinuousClock()
      let start = clock.now
      let result = await settleLive(state: { 0 }, callLog: MockCallLog(), pending: { 0 }, quietWindow: .milliseconds(50))
      #expect(result.settled)
      #expect(start.duration(to: clock.now) < .milliseconds(500))
    }
  }
}
