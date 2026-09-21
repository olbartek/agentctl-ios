import AgentCtlCore
import AgentCtlTCA
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: the `(launch)` step fails like any other step that did not settle (CONTRACT.md §3.1, §5),
  /// and a script — a scenario here — never runs on top of it. The CLI's side of the same rule is in
  /// `CLICommandTests`, and the bridge's launch seed in `BridgeTests`.
  @MainActor
  @Suite struct LaunchTests {
    @Test func aLaunchThatSettlesIsOK() async {
      let launch = await serially { await TinyAppConfig.headless().makeRunner().launch() }
      #expect(launch.status == .ok)
      #expect(launch.step.settled)
      #expect(launch.step.ok)
    }

    @Test func aLaunchThatNeverSettlesFails() async {
      let launch = await serially { await Restless.makeRunner().launch() }
      #expect(launch.status == .failed)
      #expect(!launch.step.settled)
      #expect(!launch.step.ok)
      let text = StepFormatter.text(launch.step)
      #expect(text.contains("screen=restless settled=false"), "\(text)")
      #expect(text.contains("FAIL did not settle within the time limit"), "\(text)")
    }

    /// The script would pass on its own; it fails because the app never reached a known starting state, and its
    /// first line is never run.
    @Test func aScenarioThatStartsWithoutSettlingFails() async {
      let result = await serially {
        await ScenarioRunner.run(name: "restless", source: "expect screen=restless", make: { Restless.makeRunner() })
      }
      #expect(!result.passed)
      #expect(result.status == .failed)
      #expect(result.steps.map(\.command) == ["(launch)"])
      #expect(result.report.hasPrefix("FAIL restless\n"), "\(result.report)")
      #expect(result.report.contains("settled=false"), "\(result.report)")
    }
  }
}
