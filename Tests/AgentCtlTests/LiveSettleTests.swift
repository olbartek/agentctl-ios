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
    /// The poll interval the host uses, and a slow one like a loaded CI runner's, where polls land far apart.
    nonisolated static let pollIntervals: [Duration] = [.milliseconds(20), .milliseconds(60)]

    @Test(arguments: pollIntervals) func aBusyUIHoldsSettlingUntilItIsIdle(pollInterval: Duration) async {
      let clock = ContinuousClock()
      let start = clock.now
      let busyFor = Duration.milliseconds(300)
      let result = await settleLive(
        state: { 0 },
        callLog: MockCallLog(),
        pending: { 0 },
        isUIIdle: { start.duration(to: clock.now) >= busyFor },
        quietWindow: .milliseconds(100),
        pollInterval: pollInterval
      )
      let elapsed = start.duration(to: clock.now)
      #expect(result.settled)
      // Idle after 300 ms, then quiet for the window, counted from the first poll that sees it idle: never before
      // 400 ms, however far apart the polls are, where a quiet state alone would settle after about 100 ms.
      #expect(elapsed >= .milliseconds(400), "settled after \(elapsed)")
    }

    /// A UI still busy when the ceiling comes (here a ceiling shorter than the 1 s after which busy stops holding)
    /// does not settle.
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

    /// The UI is watched on every poll, not only once the state is quiet. Here a first transition (0–80 ms) ends
    /// while the state changes (60–1200 ms, a slow response), and a second one (1100–1500 ms) starts before the
    /// state goes quiet. Watching only quiet polls would miss the idle gap, date the second transition from the
    /// first, call it endless and settle mid-animation.
    @Test(arguments: pollIntervals) func aSecondTransitionAfterALongStateChangeStillHolds(pollInterval: Duration) async {
      let clock = ContinuousClock()
      let start = clock.now
      func now() -> Duration { start.duration(to: clock.now) }
      let result = await settleLive(
        state: { now() < .milliseconds(60) || now() >= .milliseconds(1200) ? 0 : Int(now() / .milliseconds(20)) },
        callLog: MockCallLog(),
        pending: { 0 },
        isUIIdle: { !(now() < .milliseconds(80) || (now() >= .milliseconds(1100) && now() < .milliseconds(1500))) },
        quietWindow: .milliseconds(100),
        pollInterval: pollInterval
      )
      #expect(result.settled)
      #expect(now() >= .milliseconds(1570), "settled after \(now())")
    }

    /// An endless animation (a spinner) is busy with short idle gaps between frames. After a second at a stretch it
    /// stops holding settling, so a screen with a spinner still settles.
    @Test(arguments: pollIntervals) func anEndlessAnimationStopsHoldingAfterASecond(pollInterval: Duration) async {
      let clock = ContinuousClock()
      let start = clock.now
      var polls = 0
      let result = await settleLive(
        state: { 0 },
        callLog: MockCallLog(),
        pending: { 0 },
        // Idle for one poll in three, as between a spinner's frames. Counted in polls, not time: a time pattern
        // aliases with polls that a loaded machine spaces out, and every poll can land in an idle gap. A lone idle
        // poll never ends a stretch, however far apart the polls are.
        isUIIdle: {
          polls += 1
          return polls % 3 == 0
        },
        quietWindow: .milliseconds(100),
        pollInterval: pollInterval
      )
      let elapsed = start.duration(to: clock.now)
      #expect(result.settled)
      #expect(elapsed >= .milliseconds(1000), "settled after \(elapsed)")
    }

    /// The trace says what held the step, when it changes, and how settling ended: what a step that does not settle
    /// in someone else's app is explained by.
    @Test func theTraceSaysWhatHeldTheStep() async {
      // Scripted in polls, not time, so a loaded machine cannot reorder it: the state changes on polls 1-2, a call
      // runs until poll 4, the UI is busy on polls 4-6, then all is quiet.
      let log = MockCallLog()
      log.begin("auth.login")
      var polls = 0
      var lines: [String] = []
      let result = await settleLive(
        state: {
          polls += 1
          return min(polls, 3)
        },
        callLog: log,
        pending: { 0 },
        isUIIdle: {
          if polls >= 5 { log.end("auth.login") }
          return !(5...7).contains(polls)
        },
        quietWindow: .milliseconds(100),
        trace: { lines.append($0) }
      )
      #expect(result.settled)
      let what = lines.map { $0.split(separator: " ", maxSplits: 2).last.map(String.init) ?? $0 }
      #expect(what == ["state changing", "calls in flight: auth.login", "UI busy", "UI let go", "quiet", "settled"], "\(lines)")
      #expect(lines.allSatisfy { $0.hasPrefix("+") && $0.contains(" ms ") }, "\(lines)")
    }

    @Test func aStepThatDoesNotSettleSaysWhatHeldItLast() async {
      var lines: [String] = []
      let log = MockCallLog()
      log.begin("visits.fetchDetail")
      let result = await settleLive(
        state: { 0 }, callLog: log, pending: { 0 }, quietWindow: .milliseconds(50), limit: .milliseconds(200),
        trace: { lines.append($0) }
      )
      #expect(!result.settled)
      #expect(lines.last?.hasSuffix("did not settle within 0.2 seconds; last: calls in flight: visits.fetchDetail") == true, "\(lines)")
    }

    /// A sign-in that chains four calls (unlock, sign in, profile, list) at a second each takes longer than the old 3 s
    /// ceiling and well under the live one: it settles, once the last call is done.
    @Test func aChainOfCallsLongerThanThreeSecondsSettles() async {
      let clock = ContinuousClock()
      let start = clock.now
      let log = MockCallLog()
      let calls = ["credentials.unlock", "auth.signIn", "patient.profiles", "visits.appointments"]
      var started = 0
      func advance() {
        // Call n runs from second n to second n+1, back to back.
        let due = min(Int(start.duration(to: clock.now) / .seconds(1)), calls.count)
        while started < due + (due < calls.count ? 1 : 0) {
          if started > 0 { log.end(calls[started - 1]) }
          if started < calls.count { log.begin(calls[started]) }
          started += 1
        }
        if due == calls.count, log.inFlight > 0 { log.end(calls[calls.count - 1]) }
      }
      let result = await settleLive(
        state: { advance(); return started },
        callLog: log,
        pending: { 0 },
        quietWindow: .milliseconds(250),
        limit: liveSettleLimit
      )
      let elapsed = start.duration(to: clock.now)
      #expect(result.settled)
      #expect(elapsed > .seconds(4) && elapsed < liveSettleLimit, "settled after \(elapsed)")
    }

    /// A call that never returns still fails the step, at the live ceiling.
    @Test func aCallThatNeverReturnsFailsAtTheCeiling() async {
      let clock = ContinuousClock()
      let start = clock.now
      let log = MockCallLog()
      log.begin("visits.appointments")
      let result = await settleLive(
        state: { 0 }, callLog: log, pending: { 0 }, quietWindow: .milliseconds(250), limit: liveSettleLimit
      )
      let elapsed = start.duration(to: clock.now)
      #expect(!result.settled)
      #expect(liveSettleLimit == .seconds(10))
      #expect(elapsed >= .seconds(10) && elapsed < .seconds(11), "gave up after \(elapsed)")
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
