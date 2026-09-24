import AgentCtlCore
import AgentCtlTCA
import AgentShopCtl
import Foundation
import SessionClient
import Testing

extension AppCtlSuite {
  /// What this guards: AgentShop's **live** wiring — `AgentShopConfig.live(latency:sessionStorage:)`, what the
  /// DEBUG app runs behind its agent bridge — answers a script with the same steps as the headless wiring
  /// `./appctl run` uses. The package proves this for its example app; only a test against AgentShop's own config
  /// proves it for AgentShop, whose two hosts bind their clients and backends separately.
  ///
  /// It drives the bridge's router directly, as the package's own router tests do: no server, no network, no
  /// simulator. The script starts nothing that waits on the clock (a countdown would tick on real time live and
  /// not at all headlessly), and the live host gets zero latency and in-memory session storage, so the test never
  /// touches the real `UserDefaults`.
  @MainActor
  @Suite struct BridgeTests {
    @Test func runReturnsTheSameStepsAsAppctl() async {
      let script = "login-as alice; tab orders; open 1003; cancel; back"
      let headless = await serially {
        let runner = AgentShopConfig.headless().makeRunner()
        let launch = await runner.launch()
        let result = await runner.run(script)
        #expect(launch.status == .ok)
        #expect(result.status == .ok, "\(StepFormatter.text(result.steps))")
        return StepFormatter.text(result.steps) + "\n"
      }

      let live = AgentShopConfig.live(latency: .zero, sessionStorage: .inMemory())
      // No views exist in a test, so this runner sends each screen's appearance itself, as a launch seed's does.
      let runner = live.makeRunner(synthesizesAppearance: true)
      let launch = await runner.launch()
      #expect(launch.status == .ok, "the live app did not settle at launch:\n\(StepFormatter.text(launch.step))")
      let router = BridgeRouter(runner: runner, screensText: { "" })
      let response = await router.handle(BridgeRequest(method: "POST", path: "/run", body: script))

      #expect(response.status == 200)
      #expect(response.exitCode == 0)
      #expect(response.body == headless)
      // Not vacuous: the script really went somewhere and did something.
      #expect(headless.contains("> cancel\n  screen=home/orders/1003"), "\(headless)")
    }
  }
}
