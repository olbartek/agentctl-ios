#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation

  /// The CLI's `check`: the verification ladder — build, tests, scenarios and the generated docs, then the two
  /// UI stages — cheapest first, one line per stage, stopping at the first failure.
  @MainActor
  struct Ladder {
    /// The packages L0 builds and L1 tests, in order: paths relative to the root.
    var packages: [String] { AgentCtl.runtime.packages }

    let root: URL
    var ui = false
    var simulator = AgentCtl.runtime.simulatorName
    var layout: Layout { Layout(root: root) }
    var logs: URL { layout.logs }

    /// The ladder's exit status (CONTRACT.md §5): that of its first failing rung, else 0. A rung that ran and found
    /// the app wrong is 1 — a build or test that failed, a failing scenario, stale docs, snapshots that differ, a
    /// scenario that failed in the app. A rung that could not run is 3 — a tool that could not start, no scenario
    /// files or a configured one that does not exist, no simulator, a failed install or launch, an unreachable
    /// bridge. A usage error is 2 — a bad `APPCTL_PORT` or an ambiguous `--sim`.
    func run() async -> Int32 {
      if ui {
        // A bad APPCTL_PORT is a usage error (exit 2), found before the ladder spends minutes on L0–L3.
        do {
          _ = try BridgePort.requested(flag: nil, environment: ProcessInfo.processInfo.environment)
        } catch {
          return AppCommands.fail(error)
        }
        // A scenario the config names that does not exist is a missing file (3, CONTRACT.md §5), found before
        // anything is built.
        if let missing = Self.missingScenario(AgentCtl.runtime.appCheck.scenario, in: scenariosDirectory) {
          report("L4 app", ok: false, detail: "no scenario to run", since: .now)
          print("  cannot read \(missing.path(percentEncoded: false))")
          return RunStatus.internalError.rawValue
        }
      }
      try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      var rungs: [@MainActor () async -> RunStatus] = [build, test, scenarios, docs]
      if ui { rungs += [snapshots, app] }
      for rung in rungs {
        let status = await rung()
        guard status == .ok else { return status.rawValue }
      }
      return 0
    }

    var scenariosDirectory: URL { root.appending(path: AgentCtl.runtime.scenariosPath) }

    /// The file of the scenario L4 is configured to run, when it does not exist; `nil` when it does or none is named.
    /// Checked before L0, so a typo in the config does not cost a build.
    static func missingScenario(_ name: String?, in directory: URL) -> URL? {
      guard let name else { return nil }
      let file = directory.appending(path: "\(name).appctl")
      return FileManager.default.fileExists(atPath: file.path) ? nil : file
    }

    /// L3: view snapshots on the config's snapshot simulator.
    private func snapshots() -> RunStatus {
      let start = ContinuousClock.now
      let result = SnapshotRunner.run(root: root, simulator: AgentCtl.runtime.snapshotSimulatorName, record: false)
      report("L3 snapshots", ok: result.ok, detail: "\(result.tests) screens", since: start)
      result.details.forEach { print("  \($0)") }
      return result.status
    }

    /// L4: the real app. Launch it seeded on a simulator, run a scenario through its agent bridge, check the state,
    /// save one screenshot.
    private func app() async -> RunStatus {
      let start = ContinuousClock.now
      let check = AgentCtl.runtime.appCheck
      let scenarios = scenariosDirectory
      guard let scenario = check.scenario ?? Self.firstScenario(in: ScenarioRunner.files(in: scenarios)) else {
        report("L4 app", ok: false, detail: "no scenario to run", since: start)
        return .internalError
      }
      do {
        let requested = try BridgePort.requested(flag: nil, environment: ProcessInfo.processInfo.environment)
        let (device, port, token, _) = try await AppCommands.launchApp(
          root: root, seed: check.seed, simulator: simulator, latency: nil, clearSession: true, build: true,
          port: requested
        )
        let script = try String(contentsOf: scenarios.appending(path: "\(scenario).appctl"), encoding: .utf8)
        // The launch's own token, kept in memory.
        let bridge = BridgeClient(port: port, token: token)
        let run = try await bridge.send("POST", "/run", body: script)
        // Every response is checked, as `app test` checks them (CONTRACT.md §8.6): another app's is not this one's.
        guard run.identity.isOurs else {
          report("L4 app", ok: false, detail: "another app answered", since: start)
          print("  \(Message.anotherAppAnswered(port: port, answeredAs: run.identity))")
          return .internalError
        }
        if let refused = run.refusal(port: port) { throw refused }
        guard run.exitCode == 0 else {
          report("L4 app", ok: false, detail: "\(scenario) failed in the app", since: start)
          print(run.body.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
          // Whatever the scenario's own code, a scenario that failed fails the rung, as in `test` (CONTRACT.md §5).
          return .failed
        }
        if let expected = check.expectScreen {
          let snapshot = try await bridge.send("GET", "/snapshot")
          guard snapshot.identity.isOurs else {
            report("L4 app", ok: false, detail: "another app answered", since: start)
            print("  \(Message.anotherAppAnswered(port: port, answeredAs: snapshot.identity))")
            return .internalError
          }
          if let refused = snapshot.refusal(port: port) { throw refused }
          guard Self.shows(expected, snapshot.body) else {
            report("L4 app", ok: false, detail: "unexpected final screen", since: start)
            print("  \(snapshot.body)")
            return .failed
          }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let screenshot = layout.screenshots.appending(path: "check-ui-\(stamp).png")
        try Simulator(root: root).screenshot(on: device, to: screenshot, log: logs.appending(path: "L4-screenshot.log"))
        report("L4 app", ok: true, detail: "\(scenario) via the agent bridge", since: start)
        print("  \(device.label), screenshot: \(screenshot.path(percentEncoded: false))")
        return .ok
      } catch {
        // The app could not be checked: an ambiguous --sim (2), or no simulator, a failed build, install or launch,
        // an unreachable bridge, an unreadable scenario, a failed screenshot (3).
        report("L4 app", ok: false, detail: "error", since: start)
        print("  \(error)")
        return error is UsageError ? .usage : .internalError
      }
    }

    /// The scenario L4 runs when the config names none: the first file without a `# app-test: skip` line, which
    /// `app test` would skip too.
    static func firstScenario(in files: [URL]) -> String? {
      files.first { file in
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return AppTestSkip.reason(in: source) == nil
      }?.deletingPathExtension().lastPathComponent
    }

    /// Whether a step shows `screen`: a line whose first token is `screen=<screen>`, the whole path. Not
    /// `home/orders/42` for `home/orders`, nor a summary value that contains the text.
    static func shows(_ screen: String, _ step: String) -> Bool {
      step.split(separator: "\n").contains { line in
        line.drop { $0 == " " }.prefix { $0 != " " } == "screen=\(screen)"
      }
    }

    /// L0: every package builds on the host.
    private func build() -> RunStatus {
      let start = ContinuousClock.now
      var retried: [String] = []
      for path in packages {
        let package = layout.name(ofPackage: path)
        let log = logs.appending(path: "L0-build-\(package).log")
        let status = shellWithRetry(["swift", "build", "--package-path", path, "-q"], log: log) {
          retried.append(package)
        }
        guard status == 0 else {
          report("L0 build", ok: false, detail: "\(package) failed", since: start)
          printFailure(log: log)
          return Self.rungStatus(status)
        }
      }
      report("L0 build", ok: true, detail: Self.count(packages.count, "package"), since: start)
      printRetries(retried)
      return .ok
    }

    /// L1: `swift test` in every package that has tests.
    private func test() -> RunStatus {
      let start = ContinuousClock.now
      var total = 0
      var tested = 0
      var retried: [String] = []
      for path in packages {
        let package = layout.name(ofPackage: path)
        let testsDirectory = layout.directory(ofPackage: path).appending(path: "Tests")
        guard FileManager.default.fileExists(atPath: testsDirectory.path) else { continue }
        let log = logs.appending(path: "L1-test-\(package).log")
        let status = shellWithRetry(["swift", "test", "--package-path", path], log: log) {
          retried.append(package)
        }
        guard status == 0 else {
          report("L1 test", ok: false, detail: "\(package) failed", since: start)
          printFailure(log: log)
          return Self.rungStatus(status)
        }
        tested += 1
        total += testCount(in: log)
      }
      report("L1 test", ok: true, detail: "\(Self.count(tested, "package")), \(Self.count(total, "test"))", since: start)
      printRetries(retried)
      return .ok
    }

    /// L2: every scenario, in-process. Internal rather than private so a test can run this rung on its own.
    func scenarios() async -> RunStatus {
      let start = ContinuousClock.now
      Deterministic.isEnabled = true
      defer { Deterministic.isEnabled = false }
      let directory = scenariosDirectory
      let files = ScenarioRunner.files(in: directory)
      guard !files.isEmpty else {
        report("L2 scenarios", ok: false, detail: "no scenario files", since: start)
        print("  \(Message.noScenarios(in: directory))")
        return .internalError
      }
      let results = await AgentCtl.runtime.runScenarios(files)
      let failures = results.filter { !$0.passed }
      report("L2 scenarios", ok: failures.isEmpty, detail: "\(results.count - failures.count)/\(results.count) scenarios", since: start)
      for failure in failures {
        print(failure.report.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
      }
      // As `test` exits (CONTRACT.md §5): 3 when a scenario could not be read, else 1 when one failed.
      if results.contains(where: { $0.status == .internalError }) { return .internalError }
      return failures.isEmpty ? .ok : .failed
    }

    private func docs() -> RunStatus {
      let start = ContinuousClock.now
      let file = root.appending(path: AgentCtl.runtime.docsPath)
      let upToDate = (try? String(contentsOf: file, encoding: .utf8)) == Commands.docsMarkdown
      report("docs", ok: upToDate, detail: upToDate ? "up to date" : Message.staleDocsDetail, since: start)
      return upToDate ? .ok : .failed
    }

    // MARK: - Helpers

    /// The status of an L0 or L1 rung whose tool exited with `status`: a build or test that ran and failed is the
    /// rung's verdict (1); a tool that could not start (-1) or was stopped (``Shell/timedOut``) is an environment
    /// failure (3).
    static func rungStatus(_ status: Int32) -> RunStatus {
      switch status {
      case 0: .ok
      case -1, Shell.timedOut: .internalError
      default: .failed
      }
    }

    /// Runs the command and, if it fails, once more. SwiftPM sometimes builds a package against a stale copy of
    /// a local dependency right after files were added to that dependency; the second build is correct. A real
    /// error fails both times.
    private func shellWithRetry(_ arguments: [String], log: URL, onRetrySuccess: () -> Void) -> Int32 {
      let first = shell(arguments, log: log)
      guard first != 0 else { return 0 }
      let second = shell(arguments, log: log)
      if second == 0 { onRetrySuccess() }
      return second
    }

    private func printRetries(_ retried: [String]) {
      guard !retried.isEmpty else { return }
      print("  note: \(retried.joined(separator: ", ")) passed on a second attempt (stale SwiftPM build of a local dependency)")
    }

    private func shell(_ arguments: [String], log: URL) -> Int32 {
      FileManager.default.createFile(atPath: log.path, contents: nil)
      guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
      defer { try? handle.close() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = arguments
      process.currentDirectoryURL = root
      process.standardOutput = handle
      process.standardError = handle
      do {
        try process.run()
      } catch {
        return -1
      }
      process.waitUntilExit()
      return process.terminationStatus
    }

    private func testCount(in log: URL) -> Int {
      guard let text = try? String(contentsOf: log, encoding: .utf8),
        let match = text.firstMatch(of: #/Test run with (\d+) tests?/#)
      else { return 0 }
      return Int(match.1) ?? 0
    }

    private func report(_ stage: String, ok: Bool, detail: String, since start: ContinuousClock.Instant) {
      let elapsed = start.duration(to: .now).components
      let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      print(Self.row(stage: stage, ok: ok, detail: detail, seconds: seconds))
    }

    /// "1 package", "6 packages".
    static func count(_ number: Int, _ noun: String) -> String {
      "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// One line of the ladder's report. Columns are padded to line up but never truncated: the detail can name a
    /// host's scenario, whose length the ladder does not control.
    static func row(stage: String, ok: Bool, detail: String, seconds: Double) -> String {
      func padded(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
      }
      return [
        padded(stage, to: 13),
        padded(ok ? "ok" : "FAIL", to: 5),
        padded(detail, to: 28),
        String(format: "%.1fs", seconds),
      ].joined(separator: " ")
    }

    private func printFailure(log: URL) {
      let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      let errors = text.split(separator: "\n").filter {
        $0.contains("error:") || $0.contains("recorded an issue") || $0.contains("✘")
      }
      for line in errors.prefix(20) {
        print("  \(line)")
      }
      print("  full log: \(log.path(percentEncoded: false))")
    }
  }
#endif
