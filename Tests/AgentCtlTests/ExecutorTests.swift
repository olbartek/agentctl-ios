import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: the runner's dispatch and reporting — how a script is executed against a real app, which
  /// failures are usage errors rather than assertion failures, and that two ways of reaching the same state
  /// produce the same state. It runs against the example app (`TinyApp`), so every command and mock method here
  /// is TinyApp's own.
  @MainActor
  @Suite struct ExecutorTests {
    /// Runs a script in a fresh headless app and returns the launch step plus the result.
    func run(_ script: String) async -> (launch: StepRecord, result: RunResult) {
      await serially {
        let app = TinyAppConfig.headless()
        let runner = app.makeRunner()
        let launch = await runner.launch()
        return (launch.step, await runner.run(script))
      }
    }

    @Test func launchSettlesOnTheFirstScreen() async {
      let (launch, result) = await run("expect screen=\(firstScreen) call=items.fetch pending=0")
      #expect(launch.command == "(launch)")
      #expect(launch.calls == ["items.fetch"])
      #expect(launch.settled && launch.ok)
      #expect(result.status == .ok)
    }

    @Test func parseErrorsAreUsageErrors() async {
      let (_, result) = await run("expect \"open")
      #expect(result.status == .usage)
      #expect(result.message?.contains("unterminated quote") == true)
      #expect(result.steps.isEmpty)
    }

    @Test func unknownCommandsListTheValidOnes() async {
      let (_, result) = await run("frobnicate")
      #expect(result.status == .failed)
      let message = try? #require(result.steps.last?.message)
      #expect(message?.contains("unknown command 'frobnicate' on \(firstScreen)") == true)
      #expect(message?.contains("expect, advance, mock") == true)
    }

    @Test func failedExpectationsStopTheScript() async {
      let (_, result) = await run("expect screen=nope; expect screen=\(firstScreen)")
      #expect(result.status == .failed)
      #expect(result.steps.count == 1)
      #expect(result.steps[0].message == "expected screen=nope, got screen=\(firstScreen)")
      #expect(result.failedLine?.line == 1)
    }

    @Test func malformedExpectIsAUsageError() async {
      let (_, result) = await run("expect screen")
      #expect(result.status == .usage)
    }

    @Test func mockValidation() async {
      #expect(await run("mock items.fetch network").result.status == .ok)
      #expect(await run("mock items.fetch").result.status == .usage)
      #expect(await run("mock items.nope network").result.status == .failed)
      #expect(await run("mock items.fetch kaboom").result.status == .failed)
    }

    @Test func advanceValidation() async {
      #expect(await run("advance 5m").result.status == .ok)
      #expect(await run("advance soon").result.status == .usage)
      // Too large to represent: a usage error with the usual message, not a crash.
      let overflow = await run("advance 9999999999999999h").result
      #expect(overflow.status == .usage)
      #expect(overflow.steps.last?.message == "advance needs a duration such as 500ms, 30s, 5m or 1h")
      // Each duration fits, but together they would overflow the clock: the second is refused before it moves.
      let cumulative = await run("advance \(Int.max)s; advance 1s").result
      #expect(cumulative.status == .usage)
      #expect(cumulative.steps.count == 2)
      #expect(cumulative.steps.last?.message == "advance would take the clock past \(Int.max) seconds")
    }

    /// A gate mirrors a disabled button: the command is refused with the gate's hint and no action is sent, so
    /// an agent is told which condition closed it instead of watching a command quietly do nothing.
    @Test func gatedCommandsAreRefusedWithTheirHint() async {
      let (_, refused) = await run("retry")
      #expect(refused.status == .failed)
      #expect(refused.steps.last?.message == "retry is disabled here (error=none)")
      // Nothing was sent: the list is untouched and no call was made.
      #expect(refused.steps.last?.calls == [])
      // The gate opens once there is a failure to retry.
      #expect(await run("mock items.fetch network; refresh; retry; expect error=none items=3").result.status == .ok)
    }

    /// `open` is gated on there being rows to open. The fetch at launch is the only one a script cannot reach,
    /// so this test makes it fail on the host before launching, which is the one way to see the list empty.
    @Test func openIsRefusedWhileTheListIsEmpty() async {
      let (launch, result) = await serially {
        let app = TinyAppConfig.headless()
        app.faults.set("items.fetch", code: "network")
        let runner = app.makeRunner()
        return (await runner.launch().step, await runner.run("open 2"))
      }
      #expect(launch.summary.contains(SummaryItem("items", 0)))
      #expect(launch.error == "network")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message == "open is disabled here (items=0)")
    }

    /// A leaf command is not offered on another screen: `save` belongs to the detail screen, so on the list it
    /// is an unknown command — a different refusal from a `gate:`, which is asserted above.
    @Test func commandsOfAnotherScreenAreRefused() async {
      let (_, result) = await run("save")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message?.contains("unknown command 'save' on \(firstScreen)") == true)
    }

    /// An `open` that names no existing item answers with an error code instead of a successful no-op.
    @Test func unknownIdsReportAnError() async {
      let (_, result) = await run("open 99; expect error=notFound screen=items items=3")
      #expect(result.status == .ok)
      #expect(result.steps.first?.error == "notFound")
      // The error clears as soon as an id that exists is opened.
      #expect(await run("open 99; open 2; expect screen=items/2 error=none").result.status == .ok)
    }

    @Test func jsonOutput() async throws {
      let (launch, result) = await run("expect screen=\(firstScreen)")
      let json = StepFormatter.json([launch] + result.steps)
      let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
      #expect(decoded?.count == 2)
      #expect(decoded?.first?["command"] as? String == "(launch)")
      #expect(decoded?.last?["ok"] as? Bool == true)
    }

    @Test func sessionReplayMatchesASingleRun() async {
      let (first, second) = await serially {
        let a = TinyAppConfig.headless().makeRunner()
        _ = await a.launch()
        _ = await a.run("refresh")
        _ = await a.run("advance 1s")
        let b = TinyAppConfig.headless().makeRunner()
        _ = await b.launch()
        _ = await b.run("refresh; advance 1s")
        return (a.stateDump, b.stateDump)
      }
      #expect(first == second)
    }

    /// The same assertion for a script that pushes a screen, compared on the steps rather than the state dump:
    /// a pushed element's `StackElementID` is generated per process, so two stores in one process push `#0` and
    /// `#1`. That shows in a state dump and never in a step, and a fresh `tinyctl` process always starts at
    /// `#0`, which is what keeps its output reproducible.
    @Test func splittingAScriptDoesNotChangeItsSteps() async {
      let (split, single) = await serially {
        let a = TinyAppConfig.headless().makeRunner()
        _ = await a.launch()
        let opened = await a.run("open 2")
        let saved = await a.run("save")
        let b = TinyAppConfig.headless().makeRunner()
        _ = await b.launch()
        let whole = await b.run("open 2; save")
        return (StepFormatter.text(opened.steps + saved.steps), StepFormatter.text(whole.steps))
      }
      #expect(split == single)
    }

    /// The first screen after launch.
    var firstScreen: String { "items" }
  }
}
