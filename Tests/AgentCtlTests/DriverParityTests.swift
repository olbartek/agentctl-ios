import AgentCtlCore
import AgentCtlObservation
import AgentCtlTCA
import AgentCtlTestSupport
import Foundation
import Testing
import TinyApp
import TinyMVVM

extension AgentCtlSuite {
  /// What this guards: the engine is architecture-neutral. TinyApp (TCA, `StoreDriver`) and TinyMVVM (MVVM-C,
  /// `ObservationDriver`) are the same app, and every script prints the same bytes and exits the same way on both:
  /// TinyApp's scenarios, failures of every kind, `advance`, `mock`, `device` and a relaunch.
  @MainActor
  struct DriverParityTests {
    static let scripts: [String] = {
      let scenarios = ScenarioRunner.files(in: PackageRoot.scenarios).compactMap {
        try? String(contentsOf: $0, encoding: .utf8)
      }
      return scenarios + [
        "open 2; save; advance 1m",
        "open 2; save; back",
        "back",
        "mock items.fetch timeout; refresh; retry",
        "mock items.fetch bogus",
        "open x",
        "open 9; expect error=notFound; open 1",
        "open 1; device push item-updated; device push item-updated tap",
        "retry",
        "open 2; save; open 1",
        "open 2; save; save; expect error=cooldown; advance 1s; expect cooldown=2",
        "device open-url tinyapp://items/3; device open-url tinyapp://items/x",
        "device relaunch",
      ]
    }()

    func run<Driver: AgentDriver>(_ runner: ScriptRunner<Driver>, _ script: String) async -> String {
      let launch = await runner.launch()
      let result = await runner.run(script)
      return StepFormatter.text([launch.step] + result.steps) + "\nexit=\(result.status.rawValue)"
    }

    @Test func tinyMVVMPrintsWhatTinyAppPrints() async {
      #expect(Self.scripts.count >= 18)
      for script in Self.scripts {
        let tca = await serially { await run(TinyAppConfig.headless().makeRunner(), script) }
        let mvvm = await serially { await run(TinyMVVMConfig.headless().makeRunner(), script) }
        #expect(tca == mvvm, "\(script)\n--- TCA\n\(tca)\n--- MVVM-C\n\(mvvm)")
      }
    }

    /// A relaunch throws the app away mid-countdown and after a failure, and both drivers start over alike.
    @Test func aRelaunchIsTheSameOnBothDrivers() async {
      let script = "open 2; save; expect pending=1; device relaunch; expect screen=items pending=0; "
        + "mock items.fetch network; device relaunch; expect error=network; device relaunch; open 3"
      let tca = await serially {
        await run(TinyAppConfig.headless(device: AgentDeviceConfig(relaunch: true)).makeRunner(), script)
      }
      let mvvm = await serially {
        await run(TinyMVVMConfig.headless(device: AgentDeviceConfig(relaunch: true)).makeRunner(), script)
      }
      #expect(tca.hasSuffix("exit=0"), "\(tca)")
      #expect(tca == mvvm, "--- TCA\n\(tca)\n--- MVVM-C\n\(mvvm)")
    }
  }
}

extension AgentCtlSuite {
  /// The coverage guards and scenario checks are architecture-neutral too: aimed at TinyMVVM, they hold.
  @MainActor
  struct ObservationCoverageTests {
    static func coverage() throws -> AgentCoverage<ObservationDriver<AppCoordinator>> {
      try AgentCoverage(screens: TinyMVVMConfig.screens, scenarios: PackageRoot.scenarios) {
        TinyMVVMConfig.headless().makeRunner()
      }
    }

    @Test func everyCommandIsUsedAndEveryScreenVisited() async throws {
      let coverage = try Self.coverage()
      #expect(try coverage.unusedCommands().isEmpty)
      #expect(try coverage.unusedDeviceCommands().isEmpty)
      #expect(await serially { await coverage.undocumentedSummaryKeys() }.isEmpty)
      #expect(await serially { await coverage.unvisitedScreens() }.isEmpty)
    }

    @Test func theScenarioChecksHold() async throws {
      let checks = try AgentScenarioChecks(config: TinyMVVMConfig.appCtl)
      let problems = await checks.allPass() + checks.endWithExpect() + checks.docsCurrent(root: PackageRoot.url)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
      let deterministic = await checks.deterministic(runs: 5)
      #expect(deterministic.isEmpty, "\(deterministic.joined(separator: "\n"))")
    }
  }
}
