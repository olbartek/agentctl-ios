#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
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

    func run() async -> Int32 {
      try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      guard build() else { return 1 }
      guard test() else { return 1 }
      guard await scenarios() else { return 1 }
      guard docs() else { return 1 }
      if ui {
        guard snapshots() else { return 1 }
        guard await app() else { return 1 }
      }
      return 0
    }

    /// L3: view snapshots on the config's snapshot simulator.
    private func snapshots() -> Bool {
      let start = ContinuousClock.now
      let result = SnapshotRunner.run(root: root, simulator: AgentCtl.runtime.snapshotSimulatorName, record: false)
      report("L3 snapshots", ok: result.ok, detail: "\(result.tests) screens", since: start)
      result.details.forEach { print("  \($0)") }
      return result.ok
    }

    /// L4: the real app. Launch it seeded on a simulator, run a scenario through its agent bridge, check the state,
    /// save one screenshot.
    private func app() async -> Bool {
      let start = ContinuousClock.now
      let port = Int(BridgeDefaults.port)
      let check = AgentCtl.runtime.appCheck
      let scenarios = root.appending(path: AgentCtl.runtime.scenariosPath)
      guard
        let scenario = check.scenario
          ?? ScenarioRunner.files(in: scenarios).first?.deletingPathExtension().lastPathComponent
      else {
        report("L4 app", ok: false, detail: "no scenario to run", since: start)
        return false
      }
      do {
        let (device, _) = try await AppCommands.launchApp(
          root: root, seed: check.seed, simulator: simulator, latency: nil, clearSession: true, build: true,
          port: port
        )
        let script = try String(contentsOf: scenarios.appending(path: "\(scenario).appctl"), encoding: .utf8)
        let bridge = BridgeClient(port: port)
        let run = try await bridge.send("POST", "/run", body: script)
        guard run.exitCode == 0 else {
          report("L4 app", ok: false, detail: "\(scenario) failed in the app", since: start)
          print(run.body.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
          return false
        }
        if let expected = check.expectScreen {
          let snapshot = try await bridge.send("GET", "/snapshot")
          guard snapshot.body.contains("screen=\(expected)") else {
            report("L4 app", ok: false, detail: "unexpected final screen", since: start)
            print("  \(snapshot.body)")
            return false
          }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let screenshot = layout.screenshots.appending(path: "check-ui-\(stamp).png")
        try Simulator(root: root).screenshot(on: device, to: screenshot, log: logs.appending(path: "L4-screenshot.log"))
        report("L4 app", ok: true, detail: "\(scenario) via the agent bridge", since: start)
        print("  \(device.label), screenshot: \(screenshot.path(percentEncoded: false))")
        return true
      } catch {
        report("L4 app", ok: false, detail: "error", since: start)
        print("  \(error)")
        return false
      }
    }

    /// L0: every package builds on the host.
    private func build() -> Bool {
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
          return false
        }
      }
      report("L0 build", ok: true, detail: Self.count(packages.count, "package"), since: start)
      printRetries(retried)
      return true
    }

    /// L1: `swift test` in every package that has tests.
    private func test() -> Bool {
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
          return false
        }
        tested += 1
        total += testCount(in: log)
      }
      report("L1 test", ok: true, detail: "\(Self.count(tested, "package")), \(Self.count(total, "test"))", since: start)
      printRetries(retried)
      return true
    }

    /// L2: every scenario, in-process. Internal rather than private so a test can run this rung on its own.
    func scenarios() async -> Bool {
      let start = ContinuousClock.now
      Deterministic.isEnabled = true
      defer { Deterministic.isEnabled = false }
      let directory = root.appending(path: AgentCtl.runtime.scenariosPath)
      let files = ScenarioRunner.files(in: directory)
      guard !files.isEmpty else {
        report("L2 scenarios", ok: false, detail: "no scenario files", since: start)
        print("  \(Message.noScenarios(in: directory))")
        return false
      }
      let results = await AgentCtl.runtime.runScenarios(files)
      let failures = results.filter { !$0.passed }
      report("L2 scenarios", ok: failures.isEmpty, detail: "\(results.count - failures.count)/\(results.count) scenarios", since: start)
      for failure in failures {
        print(failure.report.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
      }
      return failures.isEmpty
    }

    private func docs() -> Bool {
      let start = ContinuousClock.now
      let file = root.appending(path: AgentCtl.runtime.docsPath)
      let upToDate = (try? String(contentsOf: file, encoding: .utf8)) == Commands.docsMarkdown
      report("docs", ok: upToDate, detail: upToDate ? "up to date" : Message.staleDocsDetail, since: start)
      return upToDate
    }

    // MARK: - Helpers

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
