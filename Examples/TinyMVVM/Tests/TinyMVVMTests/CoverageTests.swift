import AgentCtlObservation
import AgentCtlTestSupport
import Testing
import TinyMVVM

extension TinyMVVMSuite {
  /// The coverage guards and scenario checks are architecture-neutral too: aimed at TinyMVVM, they hold.
  @MainActor
  struct CoverageTests {
    static func coverage() throws -> AgentCoverage<AgentObservationDriver<AppCoordinator>> {
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
