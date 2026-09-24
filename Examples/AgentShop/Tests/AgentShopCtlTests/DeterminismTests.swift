import AgentCtlCore
import AgentCtlTCA
import AgentShopCtl
import Foundation
import Testing

extension AppCtlSuite {
  /// The claim `.agent/AGENTS.md` makes about this app: "The same script always prints the same output, and a
  /// test checks that." This is that test, and it has to run against **AgentShop's** config, not the package's
  /// example app: determinism is a property of the whole wiring — `AgentShopConfig.headless()`'s `TestClock`,
  /// incrementing UUIDs, fixed date, zero mock latency, fresh in-memory backends and the main serial executor —
  /// so the package proving it for TinyApp proves nothing about AgentShop. Nothing else in AgentShop's ladder
  /// covers it either: L2 runs each scenario exactly once, and no scenario or golden exercises `--session`.
  @MainActor
  @Suite struct DeterminismTests {
    nonisolated static let files = ScenarioRunner.files(in: Repo.scenarios)

    /// Not vacuous: the guard below iterates the scenario files, so an empty list would pass having run nothing.
    @Test func thereAreScenarios() {
      #expect(!Self.files.isEmpty, "no *.appctl files at \(Repo.scenarios.path)")
    }

    /// Every scenario produces byte-identical output across fresh runs. Ten runs, because the failures this
    /// catches — an unordered collection in a summary, a `Task` that settles in whatever order the cooperative
    /// pool chose, a real clock leaking into an effect — are intermittent, and a single repeat would usually
    /// agree with the first run by luck.
    @Test func scenariosAreDeterministic() async {
      for file in Self.files {
        var outputs: Set<String> = []
        for _ in 0..<10 {
          let result = await serially {
            await ScenarioRunner.run(file: file, make: { AgentShopConfig.headless().makeRunner() })
          }
          outputs.insert(StepFormatter.text(result.steps))
        }
        #expect(outputs.count == 1, "\(file.lastPathComponent) produced \(outputs.count) different outputs")
      }
    }

    /// What `--session` promises: resuming a session replays the saved commands into a fresh runner, so it must
    /// land in exactly the state one uninterrupted run would have reached. The same script run in three `run`
    /// calls against one runner versus in one, compared by full state dump. The script signs in — every line
    /// changes the state, from the login form to the shop — and every run must pass, so the two dumps can
    /// only agree by reaching the same place, not by both going nowhere.
    @Test func sessionReplayMatchesASingleRun() async {
      let parts = [
        "email alice@example.com; password Passw0rd!",
        "submit; expect screen=home/shop products=12",
        "advance 1s",
      ]
      let (initial, split, single) = await serially {
        let fresh = AgentShopConfig.headless().makeRunner()
        let freshLaunch = await fresh.launch()
        #expect(freshLaunch.status == .ok)

        let a = AgentShopConfig.headless().makeRunner()
        let aLaunch = await a.launch()
        #expect(aLaunch.status == .ok)
        for part in parts {
          let result = await a.run(part)
          #expect(result.status == .ok, "\(part):\n\(StepFormatter.text(result.steps))")
        }

        let b = AgentShopConfig.headless().makeRunner()
        let bLaunch = await b.launch()
        #expect(bLaunch.status == .ok)
        let whole = await b.run(parts.joined(separator: "; "))
        #expect(whole.status == .ok, "\(StepFormatter.text(whole.steps))")
        #expect(whole.steps.count == 5)
        return (fresh.stateDump, a.stateDump, b.stateDump)
      }
      #expect(split == single)
      #expect(split != initial, "the script left the state where launch put it")
    }
  }
}
