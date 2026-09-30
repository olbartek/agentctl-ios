import AgentCtlCore
import AgentCtlTCA
import AgentCtlTestSupport
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// `AgentScenarioChecks` can fail, and says why: each check is run against a throwaway repo of scenario files
  /// that breaks exactly one promise, beside one that keeps it. `ScenarioTests` runs the same checks against the
  /// example's real scenarios, where they must all pass — which on its own would not tell a working check from one
  /// that never reports anything.
  @MainActor
  @Suite struct AgentScenarioChecksTests {
    /// A repo root in a fresh temporary directory, holding `scenarios/<name>.appctl` for each entry.
    static func repo(_ scenarios: [String: String]) throws -> URL {
      let root = FileManager.default.temporaryDirectory.appending(path: "agentctl-checks-\(UUID().uuidString)")
      let directory = root.appending(path: "scenarios")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, source) in scenarios {
        try source.write(to: directory.appending(path: "\(name).appctl"), atomically: true, encoding: .utf8)
      }
      return root
    }

    /// TinyApp's config, pointed at a fixture repo's layout. `drifting` swaps in an app whose list grows by one item
    /// per fetch across the whole process: every fresh run, and every part of a split run, sees a different list.
    static func config(drifting: Bool = false) -> AppCtlConfig<TinyRoot> {
      var config = TinyAppConfig.appCtl
      config.scenariosPath = "scenarios"
      config.docsPath = "agent-commands.md"
      if drifting {
        config.makeHeadless = {
          HeadlessHost(initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, mockMethods: []) { deps, _ in
            deps.itemsClient = ItemsClient(fetch: {
              let count = fetches.withValue { count in
                count += 1
                return count
              }
              return Array(Item.seed.prefix(count % Item.seed.count + 1))
            })
          }
        }
      }
      return config
    }

    nonisolated static let fetches = LockIsolated(0)

    static func checks(_ scenarios: [String: String], drifting: Bool = false) throws -> AgentScenarioChecks<TinyRoot> {
      try AgentScenarioChecks(config: config(drifting: drifting), root: repo(scenarios))
    }

    static let good = ["open": "open 2\nexpect screen=items/2 saved=false\nback\nexpect screen=items items=3"]

    // MARK: - Construction

    @Test func initThrowsWhenThereAreNoScenarios() throws {
      let root = try Self.repo([:])
      #expect(throws: NoScenariosFound(scenarios: root.appending(path: "scenarios"))) {
        try AgentScenarioChecks(config: Self.config(), root: root)
      }
    }

    @Test func theRootIsFoundFromTheCallersFile() throws {
      let checks = try AgentScenarioChecks(config: TinyAppConfig.appCtl)
      #expect(checks.root.standardizedFileURL == PackageRoot.url.standardizedFileURL)
      let names = checks.files.map(\.lastPathComponent)
      #expect(names == ["browse.appctl", "refresh-error.appctl", "save-cooldown.appctl"])
    }

    @Test func repoRootWalksUpToTheMarker() throws {
      let root = try Self.repo([:])
      try "".write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
      let nested = root.appending(path: "scenarios/deeper")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      #expect(RepoRoot.find(marker: "Package.swift", from: nested)?.path == root.standardizedFileURL.path)
      #expect(RepoRoot.find(marker: "no-such-marker-\(UUID().uuidString)", from: nested) == nil)
    }

    // MARK: - allPass

    @Test func allPassReportsTheFailingScenario() async throws {
      #expect(try await Self.checks(Self.good).allPass().isEmpty)
      let problems = try await Self.checks(Self.good.merging(["wrong": "expect items=4"]) { $1 }).allPass()
      #expect(problems.count == 1)
      #expect(problems.first?.hasPrefix("FAIL wrong:1") == true, "\(problems)")
      #expect(problems.first?.contains("items=3") == true, "the report shows the failing step: \(problems)")
    }

    // MARK: - endWithExpect

    @Test func endWithExpectNamesTheScenarioAndItsLastCommand() throws {
      #expect(try Self.checks(Self.good).endWithExpect().isEmpty)
      let problems = try Self.checks(["open": "open 2\nexpect screen=items/2\nsave"]).endWithExpect()
      #expect(problems == ["open.appctl ends with `save` (line 3), not an expect"])
    }

    // MARK: - deterministic

    @Test func deterministicReportsOutputThatChangesBetweenRuns() async throws {
      #expect(try await Self.checks(Self.good).deterministic(runs: 3).isEmpty)
      let problems = try await Self.checks(["list": "expect screen=items"], drifting: true).deterministic(runs: 3)
      #expect(problems.count == 1, "\(problems)")
      let problem = problems.first ?? ""
      #expect(problem.hasPrefix("list.appctl produced 3 different outputs in 3 runs;"), "\(problem)")
      #expect(problem.contains("first difference at line 2:\n  run 1:   screen=items items="), "\(problem)")
    }

    // MARK: - sessionReplayMatches

    @Test func sessionReplayMatchesPassesForADeterministicApp() async throws {
      let cooldown = "open 2\nsave\nadvance 1s\nexpect cooldown=2"
      let checks = try Self.checks(Self.good.merging(["cooldown": cooldown]) { $1 })
      #expect(await checks.sessionReplayMatches(parts: 2).isEmpty)
      // More parts than lines: one line per part.
      #expect(await checks.sessionReplayMatches(parts: 10).isEmpty)
    }

    @Test func sessionReplayReportsASplitRunThatDiffers() async throws {
      let checks = try Self.checks(["list": "open 1\nback\nexpect screen=items"], drifting: true)
      let problems = await checks.sessionReplayMatches(parts: 3)
      #expect(problems.count == 1, "\(problems)")
      #expect(
        problems.first?.hasPrefix("list.appctl: the steps of a run split into 3 parts differ from one run;") == true,
        "\(problems)"
      )
    }

    @Test func sessionReplaySkipsAScenarioThatAlreadyFails() async throws {
      let problems = try await Self.checks(["wrong": "open 2\nexpect items=4"]).sessionReplayMatches(parts: 2)
      #expect(problems == ["wrong.appctl fails in one run, so its session replay was not compared"])
    }

    // MARK: - docsCurrent

    @Test func docsCurrentComparesWithTheCLIsRendering() throws {
      let checks = try Self.checks(Self.good)
      let file = checks.root.appending(path: "agent-commands.md")
      #expect(checks.docsCurrent() == ["agent-commands.md does not exist at \(file.path). Run swift run tinyctl docs."])

      try checks.config.docsMarkdown.write(to: file, atomically: true, encoding: .utf8)
      #expect(checks.docsCurrent().isEmpty)

      try "# Old title\n".write(to: file, atomically: true, encoding: .utf8)
      let problems = checks.docsCurrent()
      #expect(problems.count == 1)
      #expect(problems.first?.hasPrefix("agent-commands.md is stale. Run swift run tinyctl docs.") == true)
      #expect(problems.first?.contains("committed: # Old title\n  generated: # TinyApp agent commands") == true)
    }

    // MARK: - readmeListsAll

    @Test func readmeListsAllReportsBothDirections() throws {
      let checks = try Self.checks(["a": "expect screen=items", "b": "expect screen=items"])
      let readme = checks.scenarios.appending(path: "README.md")
      let unreadable = "cannot read \(readme.path): the scenarios README must list every scenario file"
      #expect(checks.readmeListsAll() == [unreadable])

      // A path before the name counts; a glob and an unquoted mention do not.
      try "Run `*.appctl`. | `a.appctl` | see b.appctl | [`scenarios/b.appctl`](scenarios/b.appctl) |"
        .write(to: readme, atomically: true, encoding: .utf8)
      #expect(checks.readmeListsAll().isEmpty)

      try "| `a.appctl` |\n| `gone.appctl` |\nsee b.appctl".write(to: readme, atomically: true, encoding: .utf8)
      #expect(
        checks.readmeListsAll() == [
          "README.md does not list: b.appctl", "README.md names files that are not in scenarios: gone.appctl",
        ]
      )
    }

    // MARK: - noStepShows

    @Test func noStepShowsFindsASecretInAStepIgnoringCase() async throws {
      let checks = try Self.checks(Self.good)
      #expect(await checks.noStepShows(secrets: ["hunter2"]).isEmpty)
      // Both the step that opened the item and the `expect` after it print its title.
      let problems = await checks.noStepShows(secrets: ["SECOND ITEM"])
      #expect(problems.count == 2, "\(problems)")
      let first = problems.first ?? ""
      #expect(first.hasPrefix("open.appctl: `SECOND ITEM` in `open 2`:   screen=items/2"), "\(problems)")
    }

    /// The echo (`> open 2`) is what the agent sent; only what the app printed back is scanned.
    @Test func noStepShowsLeavesTheEchoOut() async throws {
      #expect(try await Self.checks(Self.good).noStepShows(secrets: ["open 2"]).isEmpty)
    }

    @Test func noStepShowsForbidsWhatAScenarioTypesIntoAPersonalCommand() async throws {
      let problems = try await Self.checks(Self.good).noStepShows(secrets: [], personalCommands: ["open"])
      let step = "screen=items/2 title=\"Second item\" saved=false cooldown=0"
      #expect(
        problems == [
          "open.appctl: `2` in `open 2`:   \(step)",
          "open.appctl: `2` in `expect screen=items/2 saved=false`:   \(step)",
        ]
      )
    }

    @Test func noStepShowsRefusesToScanForNothing() async throws {
      let checks = try Self.checks(Self.good)
      #expect(
        await checks.noStepShows(secrets: ["hunter2"], personalCommands: ["password"]) == [
          "no scenario types `password`, so none of its values is scanned for"
        ]
      )
      #expect(
        await checks.noStepShows(secrets: []) == [
          "nothing to scan for: no secrets were given and no scenario types a personal command"
        ]
      )
    }
  }
}
