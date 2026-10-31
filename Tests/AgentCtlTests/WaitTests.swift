import AgentCtlCore
import AgentCtlTCA
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: `wait` headlessly (CONTRACT.md §2.5). The virtual clock moves from one sleep's deadline to the
  /// next and stops at the one that brings the match, so a wait is as deterministic as `advance`; a wait that times
  /// out has moved the clock its whole duration. TinyApp's `save` starts a three-second cooldown that ticks once a
  /// second.
  @MainActor
  @Suite struct WaitTests {
    func run(_ script: String) async throws -> RunResult {
      try await serially {
        let runner = TinyAppConfig.headless().makeRunner()
        _ = await runner.launch()
        return try await runner.run(script)
      }
    }

    @Test func aWaitStopsTheClockAtTheMatch() async throws {
      let result = try await run("open 2; save; wait cooldown=1; expect pending=1; advance 1s; expect cooldown=0 pending=0")
      #expect(result.status == .ok, "\(result.steps.last?.message ?? "")")
      #expect(StepFormatter.text([result.steps[2]]) == """
        > wait cooldown=1
          screen=items/2 title="Second item" saved=true cooldown=1 pending=1
        """)
    }

    @Test func aWaitThatAlreadyMatchesTakesNoTime() async throws {
      let result = try await run("open 2; save; wait cooldown=3; advance 3s; expect cooldown=0")
      #expect(result.status == .ok)
    }

    @Test func aTimedOutWaitFailsWithWhatItSaw() async throws {
      let result = try await run("open 2; save; wait 2s cooldown=0 saved=true")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message == "wait timed out after 2s\nexpected cooldown=0, got cooldown=1")
      #expect(result.failedLine?.text == "wait 2s cooldown=0 saved=true")
    }

    @Test func aTimedOutWaitHasMovedTheClockItsWholeDuration() async throws {
      // Nothing sleeps on the list, so the wait goes straight to its end: 90 s later on the app's clock.
      let result = try await run("wait 90s screen=items/2")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message == "wait timed out after 90s\nexpected screen=items/2, got screen=items")
    }

    @Test func aBareWaitReturnsOnTheNextChange() async throws {
      let result = try await run("open 2; save; wait; expect cooldown=2; wait; wait; expect cooldown=0 pending=0")
      #expect(result.status == .ok, "\(result.steps.last?.message ?? "")")
    }

    @Test func aBareWaitWithNothingComingTimesOut() async throws {
      let result = try await run("wait")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message == "wait timed out after 10s\nnothing changed")
    }

    @Test func callMeansACallMadeDuringTheWait() async throws {
      let result = try await run("wait 1m call=items.fetch")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message == "wait timed out after 1m\nexpected call=items.fetch, got calls=none")
    }

    @Test func aKeyTheScreenDoesNotHaveYetIsNotAMatchYet() async throws {
      let result = try await run("wait 1s cooldown=0")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message?.hasPrefix("wait timed out after 1s\nunknown key 'cooldown' on items") == true)
    }

    @Test func malformedWaitsAreUsageErrors() async throws {
      for script in ["wait x", "wait 5s foo", "wait 1h30m", "wait \"title=a b\""] {
        let result = try await run(script)
        #expect(result.status == .usage, "\(script)")
      }
    }

    @Test func aWaitCountsTowardTheClockLimit() async throws {
      let result = try await run("advance \(Int.max)s; wait 1s")
      #expect(result.status == .usage)
      #expect(result.steps.last?.message == "wait would take the clock past \(Int.max) seconds")
    }

    @Test func parsing() throws {
      #expect(try WaitArguments.parse(nil) == WaitArguments(duration: .seconds(10)))
      #expect(try WaitArguments.parse("500ms") == WaitArguments(duration: .milliseconds(500)))
      #expect(
        try WaitArguments.parse("screen=items title=\"Second item\"")
          == WaitArguments(expectation: Expectation(pairs: [.init("screen", "items"), .init("title", "Second item")]))
      )
      #expect(
        try WaitArguments.parse("30s screen=items")
          == WaitArguments(duration: .seconds(30), expectation: Expectation(pairs: [.init("screen", "items")]))
      )
      #expect(throws: ExpectationSyntaxError.self) { try WaitArguments.parse("screen=items 30s") }
      #expect(ScriptParser.formatDuration(.milliseconds(1500)) == "1500ms")
      #expect(ScriptParser.formatDuration(.seconds(90)) == "90s")
      #expect(ScriptParser.formatDuration(.seconds(300)) == "5m")
      #expect(ScriptParser.formatDuration(.seconds(7200)) == "2h")
      #expect(ScriptParser.formatDuration(.zero) == "0s")
    }
  }
}
