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
        return (launch, await runner.run(script))
      }
    }

    @Test func launchSettlesOnTheFirstScreen() async {
      let (launch, result) = await run("expect screen=\(firstScreen) call=items.fetch pending=0")
      #expect(launch.command == "(launch)")
      #expect(launch.calls == ["items.fetch"])
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
    }

    /// A disabled command is refused before it reaches the app: `save` only exists on the detail screen.
    @Test func commandsOfAnotherScreenAreRefused() async {
      let (_, result) = await run("save")
      #expect(result.status == .failed)
      #expect(result.steps.last?.message?.contains("unknown command 'save' on \(firstScreen)") == true)
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
