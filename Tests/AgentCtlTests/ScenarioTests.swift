import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: the example's scenarios all pass under `swift test`, not only under `tinyctl test`, and
  /// the output they produce is byte-identical across fresh runs — the determinism the whole toolkit rests on.
  @MainActor
  @Suite struct ScenarioTests {
    nonisolated static let files = ScenarioRunner.files(in: PackageRoot.scenarios)

    @Test func thereAreScenarios() {
      #expect(!Self.files.isEmpty)
    }

    /// `tinyctl test` and `swift test` must run the same files: the CLI finds them through the config's
    /// `scenariosPath`, relative to the repo root, and this suite finds them from its own source file.
    @Test func theConfigPointsAtTheseScenarios() {
      #expect(TinyAppConfig.appCtl.scenariosPath == "Examples/TinyApp/scenarios")
      let fromConfig = PackageRoot.url.appending(path: TinyAppConfig.appCtl.scenariosPath)
      #expect(ScenarioRunner.files(in: fromConfig) == Self.files)
    }

    @Test(arguments: files)
    func scenarioPasses(_ file: URL) async {
      let result = await serially { await ScenarioRunner.run(file: file, make: { TinyAppConfig.headless().makeRunner() }) }
      #expect(result.passed, "\(result.report)")
    }

    /// Every scenario produces byte-identical output across fresh runs.
    @Test func scenariosAreDeterministic() async {
      for file in Self.files {
        var outputs: Set<String> = []
        for _ in 0..<10 {
          let result = await serially { await ScenarioRunner.run(file: file, make: { TinyAppConfig.headless().makeRunner() }) }
          outputs.insert(StepFormatter.text(result.steps))
        }
        #expect(outputs.count == 1, "\(file.lastPathComponent) produced \(outputs.count) different outputs")
      }
    }

    /// In a host repo this test asserted that the committed `docs/agent-commands.md` was fresh, which is what
    /// `check` does there with `docs --check`. This package commits no generated docs for the example, so what
    /// is left to guard is the step before that: the document really is rendered from the app's own registry,
    /// mock methods and prose, and nothing in the pipeline drops a screen, a command or a summary key.
    @Test func docsAreRenderedFromTheAppsRegistry() {
      let markdown = DocsRenderer.render(
        screens: TinyAppConfig.screens,
        runtimeCommands: AgentRegistry.runtimeCommands,
        mockMethods: TinyAppConfig.mockMethods,
        text: TinyAppConfig.docsText
      )
      #expect(markdown.contains("# TinyApp agent commands"))
      #expect(markdown.contains("### `items`"))
      #expect(markdown.contains("### `items/<id>`"))
      #expect(markdown.contains("Summary keys: `items`, `loading`."))
      #expect(markdown.contains("Summary keys: `title`, `saved`, `cooldown`."))
      #expect(markdown.contains("| `open <id>` |"))
      #expect(markdown.contains("| `refresh` |"))
      #expect(markdown.contains("| `save` |"))
      // `back` is the container's command, inherited by the pushed screen.
      #expect(markdown.contains("| `back` | Go back to the list. | TinyRoot |"))
      #expect(markdown.contains("| `items.fetch` | `network`, `timeout` |"))
    }
  }
}
