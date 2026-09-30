import AgentCtlCore
import AgentCtlTCA
import AgentCtlTestSupport
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: the example's scenarios all pass under `swift test`, not only under `tinyctl test`, and
  /// the promises the toolkit makes about them hold — byte-identical output across fresh runs, a `--session` run
  /// that resumes where it left off, a command reference that is current. The checks are `AgentScenarioChecks`,
  /// the same ones a host app runs against its own config.
  @MainActor
  @Suite struct ScenarioTests {
    nonisolated static let files = ScenarioRunner.files(in: PackageRoot.scenarios)

    /// Throwing, because `init` refuses to build checks that would find no scenarios, or no repo root, to check.
    static func checks() throws -> AgentScenarioChecks<TinyRoot> {
      try AgentScenarioChecks(config: TinyAppConfig.appCtl)
    }

    /// `tinyctl test` and `swift test` must run the same files: the CLI finds them through the config's
    /// `scenariosPath`, relative to the repo root, and so do the checks, which find the root from this file.
    @Test func theConfigPointsAtTheseScenarios() throws {
      #expect(TinyAppConfig.appCtl.scenariosPath == "Examples/TinyApp/scenarios")
      let checks = try Self.checks()
      #expect(checks.root.standardizedFileURL == PackageRoot.url.standardizedFileURL)
      #expect(checks.files.map(\.lastPathComponent) == Self.files.map(\.lastPathComponent))
      #expect(!Self.files.isEmpty)
    }

    @Test func everyScenarioPasses() async throws {
      let problems = try await Self.checks().allPass()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func everyScenarioEndsWithAnExpect() throws {
      let problems = try Self.checks().endWithExpect()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func scenariosAreDeterministic() async throws {
      let problems = try await Self.checks().deterministic(runs: 10)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func aSessionReplayMatchesASingleRun() async throws {
      let problems = try await Self.checks().sessionReplayMatches(parts: 3)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The example's README is its scenario index; TinyApp keeps it beside the app rather than in `scenarios/`.
    @Test func theReadmeListsEveryScenario() throws {
      let readme = PackageRoot.url.appending(path: "Examples/TinyApp/README.md")
      let problems = try Self.checks().readmeListsAll(readme: readme)
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The example's committed command reference is up to date — the same guard a host gets from `docs --check`,
    /// which is part of its `check` ladder. `tinyctl docs` regenerates the file.
    @Test func docsAreUpToDate() throws {
      let problems = try Self.checks().docsCurrent()
      #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    static var docsMarkdown: String { TinyAppConfig.appCtl.docsMarkdown }

    /// What the file above must contain: the document really is rendered from the app's own registry, mock
    /// methods and prose, and nothing in the pipeline drops a screen, a command, a gate or a summary key.
    @Test func docsAreRenderedFromTheAppsRegistry() {
      let markdown = Self.docsMarkdown
      #expect(markdown.contains("# TinyApp agent commands"))
      #expect(markdown.contains("### `items`"))
      #expect(markdown.contains("### `items/<id>`"))
      #expect(markdown.contains("Summary keys: `items`, `loading`."))
      #expect(markdown.contains("Summary keys: `title`, `saved`, `cooldown`."))
      #expect(markdown.contains("| `open <id>` |"))
      #expect(markdown.contains("| `refresh` |"))
      // A gate is documented as the condition that closes it.
      #expect(markdown.contains("*(disabled when items=0)*"))
      #expect(markdown.contains("*(disabled when error=none)*"))
      #expect(markdown.contains("| `save` |"))
      // `back` is the container's command, inherited by the pushed screen.
      #expect(markdown.contains("| `back` | Go back to the list. | TinyRoot |"))
      #expect(markdown.contains("| `items.fetch` | `network`, `timeout` |"))
    }
  }
}
