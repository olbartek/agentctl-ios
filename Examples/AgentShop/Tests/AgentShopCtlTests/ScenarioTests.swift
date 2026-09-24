import AgentCtlCore
import AgentCtlTCA
import AgentShopCtl
import Foundation
import Testing

extension AppCtlSuite {
  /// What this guards: `swift test` covers what `./appctl test` and `./appctl docs --check` cover, so the host
  /// tests alone catch a failing scenario or a stale command reference — the two guards the in-repo agent layer had
  /// before the extraction (`AgentKitTests/ScenarioTests`), ported to the package's API.
  @MainActor
  @Suite struct ScenarioTests {
    nonisolated static let files = ScenarioRunner.files(in: Repo.scenarios)

    /// Not vacuous: `scenarioPasses` is parameterized over these files, and zero files would run zero tests.
    @Test func thereAreScenarios() {
      #expect(!Self.files.isEmpty, "no *.appctl files at \(Repo.scenarios.path)")
    }

    /// Every scenario passes against AgentShop's own headless wiring, one test case per file.
    @Test(arguments: files)
    func scenarioPasses(_ file: URL) async {
      let result = await serially {
        await ScenarioRunner.run(file: file, make: { AgentShopConfig.headless().makeRunner() })
      }
      #expect(result.passed, "\(result.report)")
    }

    /// The committed command reference is what `./appctl docs` would write today: the same rendering, from the same
    /// config, as the CLI's `docs --check`.
    @Test func docsAreUpToDate() throws {
      let path = AgentShopConfig.appCtl.docsPath
      let existing = try String(contentsOf: Repo.root.appending(path: path), encoding: .utf8)
      let rendered = DocsRenderer.render(
        screens: AgentShopConfig.screens,
        runtimeCommands: AgentRegistry.runtimeCommands(mockExample: AgentShopConfig.docsText.mockExample),
        mockMethods: AgentShopConfig.mockMethods,
        text: AgentShopConfig.docsText
      )
      #expect(existing == rendered, "\(path) is stale. Run ./appctl docs.")
    }
  }
}
