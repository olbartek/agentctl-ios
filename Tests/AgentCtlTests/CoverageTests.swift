import AgentCtlCore
import AgentCtlTCA
import AgentCtlTestSupport
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// The package eating its own dog food: `AgentCoverage`, proved against the example app's real screens and
  /// scenarios rather than a fixture built just for this test.
  @MainActor
  @Suite struct CoverageTests {
    static func coverage() throws -> AgentCoverage<TinyRoot> {
      try AgentCoverage(screens: TinyRoot.registry, scenarios: PackageRoot.scenarios) {
        TinyAppConfig.headless().makeRunner()
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
      #expect(unvisited.isEmpty, "screens no scenario visits: \(unvisited)")
    }

    /// The defect this suite exists to prevent: a wrong or empty `scenarios` path must not make the three
    /// guards above pass having examined nothing. `init` throws instead of returning a value whose guards
    /// would all vacuously succeed.
    @Test func initThrowsWhenThereAreNoScenarios() {
      let empty = PackageRoot.url.appending(path: "Examples/TinyApp/Sources/TinyApp")
      #expect(ScenarioRunner.files(in: empty).isEmpty, "fixture directory unexpectedly contains *.appctl files")
      #expect {
        try AgentCoverage(screens: TinyRoot.registry, scenarios: empty) { TinyAppConfig.headless().makeRunner() }
      } throws: { error in
        error as? NoScenariosFound == NoScenariosFound(scenarios: empty)
      }
    }
  }
}
