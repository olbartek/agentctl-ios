// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import AgentCtlTCA
  import ComposableArchitecture
  import Foundation

  /// Thrown by `AgentScenarioChecks.init` when no directory at or above the test's source file holds the config's
  /// root marker, so there is nowhere to resolve `scenariosPath` and `docsPath` from.
  public struct RepoRootNotFound: Error, Equatable, Sendable, CustomStringConvertible {
    public var marker: String
    public var start: URL

    public init(marker: String, start: URL) {
      self.marker = marker
      self.start = start
    }

    public var description: String {
      "no \(marker) at or above \(start.path) — the config's root marker (its rootMarker, or else its target's "
        + "path) must exist at the repo root; or pass `root:` to AgentScenarioChecks.init"
    }
  }

  /// The scenario guards every host app would otherwise write for itself: that `swift test` alone catches what
  /// `appctl test` and `appctl docs --check` catch, and that the promises the agent docs make — the same script
  /// prints the same output, `--session` resumes where it left off, a step never shows a secret — hold for **this
  /// app's** wiring. The package proving them for its example app proves nothing about another app, because
  /// determinism and privacy are properties of the whole config: its clocks, its seeds, its mocks.
  ///
  /// Construct one from the app's ``AppCtlConfig``; it finds the repo root the way the CLI does (by the config's
  /// root marker), but walking up from the test's own source file, then reads the `*.appctl` files at
  /// `scenariosPath` once. Every check returns the problems it found as readable lines, empty when there are none,
  /// so a test is one line:
  ///
  /// ```swift
  /// let problems = await checks.allPass()
  /// #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
  /// ```
  ///
  /// The checks that run scenarios turn on the main serial executor (``Deterministic``) for the run, as the CLI
  /// does, and restore it after. That is process-global state, so the tests that call them must not run in
  /// parallel with other tests that drive an app: put them in a `.serialized` suite.
  ///
  /// Like ``AgentCoverage``, `init` throws ``NoScenariosFound`` when there are no scenario files, so no check can
  /// pass having examined nothing.
  @MainActor
  public struct AgentScenarioChecks<Root: Reducer & AgentContainer>
  where Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    public let config: AppCtlConfig<Root>
    /// The repo root `scenariosPath` and `docsPath` are resolved against.
    public let root: URL
    /// The `*.appctl` files at ``scenarios``, sorted by name, read once when this value was constructed.
    public let files: [URL]

    /// The directory the scenario files were read from.
    public var scenarios: URL { root.appending(path: config.scenariosPath) }

    /// - Parameters:
    ///   - root: the repo root. `nil` finds it: the nearest directory at or above `filePath` that holds the config's
    ///     root marker, which is what the CLI walks up for from the working directory.
    ///   - filePath: where the search for the root starts; the caller's source file by default.
    /// - Throws: ``RepoRootNotFound`` when `root` is `nil` and no ancestor holds the marker; ``NoScenariosFound``
    ///   when the scenarios directory holds no `*.appctl` files.
    public init(config: AppCtlConfig<Root>, root: URL? = nil, filePath: StaticString = #filePath) throws {
      let start = URL(fileURLWithPath: "\(filePath)")
      guard let root = root ?? RepoRoot.find(marker: config.resolvedRootMarker, from: start) else {
        throw RepoRootNotFound(marker: config.resolvedRootMarker, start: start.deletingLastPathComponent())
      }
      let scenarios = root.appending(path: config.scenariosPath)
      let files = ScenarioRunner.files(in: scenarios)
      guard !files.isEmpty else { throw NoScenariosFound(scenarios: scenarios) }
      self.config = config
      self.root = root
      self.files = files
    }

    // MARK: - The checks

    /// Every scenario passes headlessly: what `appctl test` checks. One line per failing scenario, its
    /// `FAIL name:line` report with the failing step.
    public func allPass() async -> [String] {
      var problems: [String] = []
      for file in files {
        let result = await deterministically { await run(file) }
        if !result.passed { problems.append(result.report) }
      }
      return problems
    }

    /// Every scenario's last command is an `expect`. A scenario that ends on a plain command asserts nothing about
    /// where it ended up: its last step could report anything and it would still pass.
    public func endWithExpect() -> [String] {
      files.compactMap { file in
        let lines: [ScriptLine]
        do {
          lines = try ScriptParser.parse(try String(contentsOf: file, encoding: .utf8))
        } catch {
          return "\(file.lastPathComponent): cannot be read or parsed: \(error)"
        }
        guard let last = lines.last else { return "\(file.lastPathComponent) has no commands" }
        guard last.name != "expect" else { return nil }
        return "\(file.lastPathComponent) ends with `\(last.text)` (line \(last.line)), not an expect"
      }
    }

    /// Every scenario prints byte-identical step output across `runs` fresh runs, each against its own runner.
    ///
    /// Ten runs by default, because what this catches — an unordered collection in a summary, a task that settles
    /// in whatever order the cooperative pool chose, a real clock leaking into an effect — is intermittent, and a
    /// single repeat would usually agree with the first run by luck.
    public func deterministic(runs: Int = 10) async -> [String] {
      precondition(runs >= 2, "deterministic(runs:) compares runs with each other; it needs at least 2")
      var problems: [String] = []
      for file in files {
        var outputs: [String] = []
        for _ in 0..<runs {
          let result = await deterministically { await run(file) }
          outputs.append(StepFormatter.text(result.steps))
        }
        let distinct = Set(outputs).count
        guard distinct > 1, let other = outputs.firstIndex(where: { $0 != outputs[0] }) else { continue }
        problems.append(
          "\(file.lastPathComponent) produced \(distinct) different outputs in \(runs) runs; "
            + Self.firstDifference(outputs[0], outputs[other], labels: ("run 1", "run \(other + 1)"))
        )
      }
      return problems
    }

    /// Splitting each scenario into `parts` consecutive runs, resumed through a session the way `run --session`
    /// resumes one, prints the same steps and ends in the same state as running it in one go.
    ///
    /// This is the CLI's `--session` promise, replayed through the same library calls it makes: each part gets a
    /// fresh runner that launches, replays the lines the earlier parts executed, then runs its own lines, and adds
    /// those it executed to the session. As with `run --session`, no part prints the launch step, so the parts'
    /// steps together are compared with the single run's steps after its launch; then the final state dumps
    /// (`appctl state`) are compared. A scenario that already fails in one run is reported and not compared.
    public func sessionReplayMatches(parts: Int = 3) async -> [String] {
      precondition(parts >= 2, "sessionReplayMatches(parts:) needs at least 2 parts to replay a session")
      var problems: [String] = []
      for file in files {
        if let problem = await deterministically({ await replayProblem(file, parts: parts) }) {
          problems.append(problem)
        }
      }
      return problems
    }

    /// The committed command reference at the config's `docsPath` is what the CLI's `docs` would write today:
    /// the same rendering (``AppCtlConfig/docsMarkdown``) from the same config, so this fails exactly when
    /// `docs --check` would.
    ///
    /// - Parameter root: where `docsPath` is resolved; this value's ``root`` by default.
    public func docsCurrent(root: URL? = nil) -> [String] {
      let path = config.docsPath
      let file = (root ?? self.root).appending(path: path)
      let regenerate = "Run \(config.help.invocation) docs."
      guard let existing = try? String(contentsOf: file, encoding: .utf8) else {
        return ["\(path) does not exist at \(file.path). \(regenerate)"]
      }
      let generated = config.docsMarkdown
      guard existing != generated else { return [] }
      return [
        "\(path) is stale. \(regenerate) "
          + Self.firstDifference(existing, generated, labels: ("committed", "generated"))
      ]
    }

    /// A scenarios README lists every scenario file, and names none that does not exist: the index a person or an
    /// agent reads to find a flow must not hide one or point at nothing.
    ///
    /// A file counts as listed when its name appears in backticks, optionally after a path: `` `login.appctl` ``
    /// or `` `scenarios/login.appctl` ``. Backticks, so prose that mentions a file in passing is not a listing, and
    /// a glob such as `` `*.appctl` `` matches nothing.
    ///
    /// - Parameter readme: the README to read; `README.md` in the scenarios directory by default.
    public func readmeListsAll(readme: URL? = nil) -> [String] {
      let readme = readme ?? scenarios.appending(path: "README.md")
      guard let text = try? String(contentsOf: readme, encoding: .utf8) else {
        return ["cannot read \(readme.path): the scenarios README must list every scenario file"]
      }
      let listed = Self.scenarioNames(listedIn: text)
      let onDisk = Set(files.map(\.lastPathComponent))
      var problems: [String] = []
      let missing = onDisk.subtracting(listed).sorted()
      let unknown = listed.subtracting(onDisk).sorted()
      if !missing.isEmpty {
        problems.append("\(readme.lastPathComponent) does not list: \(missing.joined(separator: ", "))")
      }
      if !unknown.isEmpty {
        problems.append(
          "\(readme.lastPathComponent) names files that are not in \(config.scenariosPath): "
            + unknown.joined(separator: ", ")
        )
      }
      return problems
    }

    /// No step any scenario prints shows a secret: neither one of `secrets` nor any value a scenario types into one
    /// of `personalCommands`, compared ignoring case (`KOWALSKA` leaks a name as much as `Kowalska`).
    ///
    /// A step is read as an agent reads it, without the echo of the command it ran (`> password hunter2` is what
    /// the agent itself sent): its `screen=… key=value …` line and any message. The forbidden values stay in the
    /// app's own test; only the scan lives here.
    ///
    /// - Parameters:
    ///   - secrets: values no step may show, such as seeded personal data or a mock's one-time code.
    ///   - personalCommands: commands whose argument is personal or secret (`email`, `password`). Every argument a
    ///     scenario file gives one of them, unquoted as the runner unquotes it, is forbidden too. Each must be
    ///     typed by at least one scenario, or its values would be scanned for nowhere — reported as a problem.
    public func noStepShows(secrets: [String], personalCommands: Set<String> = []) async -> [String] {
      var problems: [String] = []
      var typed: [String] = []
      var used: Set<String> = []
      for file in files {
        do {
          let lines = try ScriptParser.parse(try String(contentsOf: file, encoding: .utf8))
          for line in lines where personalCommands.contains(line.name) {
            used.insert(line.name)
            if let argument = line.argument { typed.append(ArgumentText.unquoted(argument)) }
          }
        } catch {
          problems.append("\(file.lastPathComponent): cannot be read or parsed: \(error)")
        }
      }
      for command in personalCommands.subtracting(used).sorted() {
        problems.append("no scenario types `\(command)`, so none of its values is scanned for")
      }
      let forbidden = Set(secrets + typed).filter { !$0.isEmpty }.sorted()
      guard !forbidden.isEmpty else {
        return problems + ["nothing to scan for: no secrets were given and no scenario types a personal command"]
      }
      var leaks: [String] = []
      for file in files {
        let result = await deterministically { await run(file) }
        if !result.passed {
          problems.append("\(file.lastPathComponent) failed, so the steps after its failure were not scanned")
        }
        for step in result.steps {
          let text = Self.summaryText(of: step)
          for value in forbidden where text.range(of: value, options: .caseInsensitive) != nil {
            leaks.append("\(file.lastPathComponent): `\(value)` in `\(step.command)`: \(text)")
          }
        }
      }
      let shown = 20
      problems += leaks.prefix(shown)
      if leaks.count > shown { problems.append("… and \(leaks.count - shown) more leaks") }
      return problems
    }

    // MARK: - Helpers

    /// A step as an agent reads it, without the echo of the command it ran: `noStepShows`'s view of a step,
    /// public so an app's own privacy tests (of a state dump, say) read steps the same way.
    nonisolated public static func summaryText(of step: StepRecord) -> String {
      StepFormatter.text(step).split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        .joined(separator: "\n")
    }

    /// Every backtick-quoted `*.appctl` file name in `text`, without its path.
    nonisolated static func scenarioNames(listedIn text: String) -> Set<String> {
      let pattern: Regex<(Substring, Substring)> = /`(?:[^`\s]*\/)?([A-Za-z0-9_.\-]+\.appctl)`/
      return Set(text.matches(of: pattern).map { String($0.output.1) })
    }

    /// `at line N: <a>` / `<b>`, the first line where two texts differ, so a failure shows where to look.
    nonisolated static func firstDifference(_ a: String, _ b: String, labels: (String, String)) -> String {
      let left = a.split(separator: "\n", omittingEmptySubsequences: false)
      let right = b.split(separator: "\n", omittingEmptySubsequences: false)
      let index = zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        ?? min(left.count, right.count)
      let describe = { (lines: [Substring]) in index < lines.count ? String(lines[index]) : "(ends)" }
      return "first difference at line \(index + 1):\n  \(labels.0): \(describe(left))\n"
        + "  \(labels.1): \(describe(right))"
    }

    private func run(_ file: URL) async -> ScenarioResult {
      await ScenarioRunner.run(file: file, make: { config.makeHeadless().makeRunner() })
    }

    /// Runs `operation` with the main serial executor, as the CLI runs every headless command, and restores it.
    private func deterministically<T>(_ operation: @MainActor () async -> T) async -> T {
      let previous = Deterministic.isEnabled
      Deterministic.isEnabled = true
      defer { Deterministic.isEnabled = previous }
      return await operation()
    }

    /// ``sessionReplayMatches(parts:)`` for one file: `nil` when the split run matches the single one.
    private func replayProblem(_ file: URL, parts: Int) async -> String? {
      let name = file.lastPathComponent
      let lines: [ScriptLine]
      do {
        lines = try ScriptParser.parse(try String(contentsOf: file, encoding: .utf8))
      } catch {
        return "\(name): cannot be read or parsed: \(error)"
      }
      let single = config.makeHeadless().makeRunner()
      guard await single.launch().status == .ok else { return "\(name): the app did not settle at launch" }
      let whole = await single.run(lines)
      guard whole.status == .ok else { return "\(name) fails in one run, so its session replay was not compared" }

      var session: [ScriptLine] = []
      var steps: [StepRecord] = []
      var last: ScriptRunner<Root>?
      for (index, part) in Self.split(lines, into: parts).enumerated() {
        let label = "\(name), part \(index + 1) of \(min(parts, lines.count))"
        let runner = config.makeHeadless().makeRunner()
        guard await runner.launch().status == .ok else { return "\(label): the app did not settle at launch" }
        // The session file holds each executed line's text, one per line; the CLI parses it back before replaying.
        if !session.isEmpty {
          let replay = await runner.run(session.map(\.text).joined(separator: "\n"))
          guard replay.status == .ok else {
            return "\(label): the session replay failed at `\(replay.failedLine?.text ?? "a line")`: "
              + (replay.message ?? replay.steps.last.map(StepFormatter.text) ?? "")
          }
        }
        let result = await runner.run(part.map(\.text).joined(separator: "\n"))
        steps += result.steps
        guard result.status == .ok else {
          return "\(label) failed after the session replay, where the single run passed:\n"
            + StepFormatter.text(result.steps.last.map { [$0] } ?? [])
        }
        session += result.executed
        last = runner
      }
      let splitText = StepFormatter.text(steps)
      let singleText = StepFormatter.text(whole.steps)
      if splitText != singleText {
        return "\(name): the steps of a run split into \(parts) parts differ from one run; "
          + Self.firstDifference(singleText, splitText, labels: ("one run", "split"))
      }
      if let last {
        let singleDump = Self.renumberingStackIDs(single.stateDump)
        let splitDump = Self.renumberingStackIDs(last.stateDump)
        if singleDump != splitDump {
          return "\(name): the state after a run split into \(parts) parts differs from one run's; "
            + Self.firstDifference(singleDump, splitDump, labels: ("one run", "split"))
        }
      }
      return nil
    }

    /// `dump` with each `StackState` element id (`#7:`) renumbered in order of first appearance (`#0:`, `#1:`, …).
    ///
    /// TCA draws those ids from one counter per process. Each `run --session` is its own process, so its replay
    /// numbers the pushed screens exactly as one run would; here every part's runner shares this process's counter,
    /// and the same screens get later numbers. Renumbering compares what the CLI would print while still catching
    /// a stack with a screen more, fewer or in another order.
    nonisolated static func renumberingStackIDs(_ dump: String) -> String {
      var numbers: [Substring: Int] = [:]
      return dump.replacing(/#(\d+):/) { match in
        let id = match.output.1
        let number = numbers[id] ?? numbers.count
        numbers[id] = number
        return "#\(number):"
      }
    }

    /// `lines` in `parts` consecutive runs of near-equal length (fewer when there are fewer lines).
    nonisolated static func split(_ lines: [ScriptLine], into parts: Int) -> [[ScriptLine]] {
      let count = min(parts, lines.count)
      guard count > 0 else { return [] }
      return (0..<count).map { index in
        Array(lines[(index * lines.count / count)..<((index + 1) * lines.count / count)])
      }
    }
  }
#endif
