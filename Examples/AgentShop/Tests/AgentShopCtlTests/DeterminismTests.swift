import AgentCtlTestSupport
import AgentShopCtl
import Foundation
import Testing

extension AppCtlSuite {
  /// The claim `.agent/AGENTS.md` makes about this app: "The same script always prints the same output, and a
  /// test checks that." It has to run against **AgentShop's** config, not the package's example app: determinism
  /// is a property of the whole wiring (`AgentShopConfig.headless()`'s `TestClock`, incrementing UUIDs, fixed date,
  /// zero mock latency, fresh in-memory backends and the main serial executor), so the package proving it for
  /// TinyApp proves nothing about AgentShop.
  @MainActor
  @Suite struct DeterminismTests {
    /// Every scenario produces byte-identical output across ten fresh runs: the failures this catches (an unordered
    /// collection in a summary, a `Task` that settles in whatever order the pool chose, a real clock leaking into
    /// an effect) are intermittent, and a single repeat would usually agree with the first run by luck.
    @Test func scenariosAreDeterministic() async throws {
      let problems = try await ScenarioTests.checks().deterministic(runs: 10)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// What `--session` promises: every scenario, split into three runs resumed through a session, prints the same
    /// steps and ends in the same state as one uninterrupted run.
    @Test func sessionReplayMatchesASingleRun() async throws {
      let problems = try await ScenarioTests.checks().sessionReplayMatches(parts: 3)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
  }
}
