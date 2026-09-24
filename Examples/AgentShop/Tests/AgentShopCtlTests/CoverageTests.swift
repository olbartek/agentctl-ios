import AgentCtlTestSupport
import AgentShopCtl
import AppFeature
import Testing

extension AppCtlSuite {
  /// The package's coverage guards, aimed at AgentShop's own registry and scenarios: every command used by a
  /// scenario, every emitted summary key documented, every screen visited.
  @MainActor
  @Suite struct CoverageTests {
    /// Throwing, because `AgentCoverage.init` refuses to build a guard that would find no scenarios to check —
    /// a wrong `scenarios` path would otherwise make all three guards below pass having examined nothing.
    static func coverage() throws -> AgentCoverage<AppFeature> {
      try AgentCoverage(screens: AppFeature.registry, scenarios: Repo.scenarios) {
        AgentShopConfig.headless().makeRunner()
      }
    }

    @Test func everyCommandIsUsedByAScenario() throws {
      let missing = try Self.coverage().unusedCommands()
      #expect(missing.isEmpty, "commands not used by any scenario: \(missing.joined(separator: ", "))")
    }

    @Test func everyEmittedSummaryKeyIsDocumented() async throws {
      let coverage = try Self.coverage()
      let undocumented = await serially { await coverage.undocumentedSummaryKeys() }
      #expect(undocumented.isEmpty, "undocumented summary keys: \(undocumented.joined(separator: "; "))")
    }

    @Test func everyScreenIsVisited() async throws {
      let coverage = try Self.coverage()
      let unvisited = await serially { await coverage.unvisitedScreens() }
      #expect(unvisited == ["launching"] || unvisited.isEmpty, "screens no scenario visits: \(unvisited)")
    }
  }
}
