import AgentCtlTestSupport
import AgentShopCtl
import AppFeature
import Foundation
import Testing

extension AppCtlSuite {
  /// What this guards: `swift test` covers what `./appctl test` and `./appctl docs --check` cover, so the host
  /// tests alone catch a failing scenario or a stale command reference, through the library's scenario checks.
  @MainActor
  @Suite struct ScenarioTests {
    static func checks() throws -> AgentScenarioChecks<AppFeature> {
      try AgentScenarioChecks(config: AgentShopConfig.appCtl)
    }

    /// Every scenario passes against AgentShop's own headless wiring (and there is at least one: the checks refuse
    /// an empty scenarios directory).
    @Test func everyScenarioPasses() async throws {
      let problems = try await Self.checks().allPass()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every scenario ends by asserting something, so none can pass having checked nothing at its end.
    @Test func everyScenarioEndsWithAnExpect() throws {
      let problems = try Self.checks().endWithExpect()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The committed command reference is what `./appctl docs` would write today.
    @Test func docsAreUpToDate() throws {
      let problems = try Self.checks().docsCurrent()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
  }
}
