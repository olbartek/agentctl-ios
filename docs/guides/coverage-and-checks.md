# The coverage guards

`AgentCtlTestSupport` fails your build when the agent surface drifts from what the app actually does. Wire it
into your own test target — this is the package's own suite, run against the example app
([`CoverageTests.swift`](../../Tests/AgentCtlTests/CoverageTests.swift); `PackageRoot.scenarios` is a URL this
repository's tests compute, and yours would too):

```swift
static func coverage() throws -> AgentCoverage<TinyRoot> {
  try AgentCoverage(screens: TinyRoot.registry, scenarios: PackageRoot.scenarios) {
    TinyAppConfig.headless().makeRunner()
  }
}

@Test func everyCommandIsUsedByAScenario() throws {
  let missing = try Self.coverage().unusedCommands()
  #expect(missing.isEmpty, "commands not used by any scenario: \(missing.joined(separator: ", "))")
}
```

- `unusedCommands()` — a command no scenario ever sends.
- `undocumentedSummaryKeys()` — a key a run emits that the screen's `summaryKeys` does not list, which would
  make the generated reference a lie.
- `unvisitedScreens()` — a documented screen path no scenario reaches. A `<id>` segment matches any concrete
  one, so a variable path needs one scenario, not one per instance.

`AgentCoverage.init` throws `NoScenariosFound` when the scenarios directory holds no `*.appctl` files, because
all three guards would otherwise pass having examined nothing.

They are deliberately shallow: they check that a command *appears* in some script, not that its result was
asserted. A thin suite that touches everything once passes them.

## The scenario checks

`AgentScenarioChecks` is the rest of what every host's test target used to write for itself: `swift test` alone
catches what `test` and `docs --check` catch, and the promises the agent docs make hold for your app's own wiring.
It takes your config, finds the repo root by the config's root marker (walking up from the test's source file;
`RepoRoot.find(marker:from:)` is the same walk the CLI makes from the working directory), and reads the scenarios
at `scenariosPath`. Each check returns its problems as readable lines, empty when there are none
([`ScenarioTests.swift`](../../Tests/AgentCtlTests/ScenarioTests.swift)):

```swift
@Test func scenariosAreDeterministic() async throws {
  let problems = try await AgentScenarioChecks(config: TinyAppConfig.appCtl).deterministic(runs: 10)
  #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
}
```

- `allPass()` — every scenario passes headlessly.
- `endWithExpect()` — every scenario's last command is an `expect`.
- `deterministic(runs:)` — each scenario prints byte-identical steps across fresh runs.
- `sessionReplayMatches(parts:)` — each scenario, split into parts resumed the way `run --session` resumes them,
  prints the same steps and ends in the same state as one run.
- `docsCurrent(root:)` — the file at `docsPath` is what `docs` would write (the same `AppCtlConfig.docsMarkdown`).
- `readmeListsAll(readme:)` — a README (`scenarios/README.md` by default) names every scenario file in backticks,
  and no file that is gone.
- `noStepShows(secrets:personalCommands:)` — no step's output (the echo of the command aside) contains a secret,
  or a value a scenario types into one of `personalCommands`, ignoring case. The values stay in your test.

The checks that run scenarios turn on the main serial executor for the run, so call them from a `.serialized`
suite. `init` throws `NoScenariosFound` when there are no scenario files, like `AgentCoverage`.
