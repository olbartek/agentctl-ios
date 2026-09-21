#if os(macOS)
  import AgentCtlTCA
  import Foundation

  /// L3: the view snapshot tests (swift-snapshot-testing) in the feature packages, run on the iOS Simulator.
  ///
  /// References live in each snapshot package's `Tests/<name>SnapshotTests/__Snapshots__/` and are recorded on the config's
  /// `snapshotSimulatorName`, on its `snapshotRuntimeMajor` runtime: a reference image is only comparable on the
  /// device and iOS version it was recorded on, which is why `resolve` below insists on that major version.
  enum SnapshotRunner {
    /// The packages whose `*SnapshotTests` run (paths relative to the root), and the iOS major version their
    /// references were recorded on.
    static var packages: [String] { AgentCtl.runtime.snapshotPackages }
    static var runtimeMajor: Int { AgentCtl.runtime.snapshotRuntimeMajor }

    struct Result {
      var ok: Bool
      var tests: Int
      var device: Simulator.Device?
      /// Lines worth showing: failing tests and where their failure images are.
      var details: [String]
    }

    static func run(root: URL, simulator: String, record: Bool) -> Result {
      let device: Simulator.Device
      do {
        device = try Simulator(root: root).resolve(simulator, runtimeMajor: runtimeMajor)
      } catch {
        return Result(ok: false, tests: 0, device: nil, details: ["\(error). Snapshots need an iOS \(runtimeMajor) simulator."])
      }
      var tests = 0
      var details: [String] = []
      var ok = true
      // Failure images (actual + difference) go here instead of the simulator's temporary directory.
      let layout = Layout(root: root)
      let artifacts = layout.snapshotFailures
      try? FileManager.default.removeItem(at: artifacts)
      try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
      for path in packages {
        let package = layout.name(ofPackage: path)
        let log = layout.logs.appending(path: "L3-snapshots-\(package).log")
        var arguments = [
          "xcodebuild", "test", "-scheme", package, "-destination", "id=\(device.udid)", "-skipMacroValidation",
          "-only-testing:\(package)SnapshotTests", "-parallel-testing-enabled", "NO",
        ]
        arguments.insert("TEST_RUNNER_SNAPSHOT_ARTIFACTS=\(artifacts.path)", at: 0)
        if record { arguments.insert("TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all", at: 0) }
        let exitStatus = Shell.runWatched(arguments, in: layout.directory(ofPackage: path), log: log) {
          $0.contains("Test run with") && ($0.contains(" passed after ") || $0.contains(" failed after "))
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // A hung xcodebuild (terminated by the watchdog) still counts when its test run finished and passed.
        let status: Int32 = exitStatus ?? (output.firstMatch(of: #/Test run with \d+ tests? .* passed after/#) != nil ? 0 : 1)
        if exitStatus == nil {
          details.append("\(package): xcodebuild didn't exit after the tests finished; it was stopped")
        }
        tests += testCount(in: output)
        if record {
          let recorded = output.components(separatedBy: "Automatically recorded snapshot").count - 1
          details.append("\(package): recorded \(recorded) snapshots")
          if recorded == 0 {
            ok = false
            details.append("  nothing recorded; log: \(log.path(percentEncoded: false))")
          }
        } else if status != 0 {
          ok = false
          details.append("\(package): failed; log: \(log.path(percentEncoded: false))")
          details += failureLines(in: output)
        }
      }
      return Result(ok: ok, tests: tests, device: device, details: details)
    }

    /// The snapshot packages' paths, for the help text.
    static var packageList: String {
      packages.isEmpty ? "no package (the config's snapshotPackages is empty)" : packages.joined(separator: ", ")
    }

    /// Where each snapshot package keeps its snapshot tests and their reference images, as paths relative to the
    /// root: what to review after recording.
    static var testDirectories: [String] {
      packages.map { path in
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed == "." || trimmed.isEmpty ? "Tests/*SnapshotTests" : "\(trimmed)/Tests/*SnapshotTests"
      }
    }

    private static func testCount(in output: String) -> Int {
      guard let match = output.firstMatch(of: #/Test run with (\d+) tests?/#) else { return 0 }
      return Int(match.1) ?? 0
    }

    /// `✘ Test <name>() failed…` plus the reference and failure image paths that follow each mismatch.
    private static func failureLines(in output: String) -> [String] {
      var lines: [String] = []
      for line in output.split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("✘ Test ") && !text.hasPrefix("✘ Test run") {
          lines.append("  " + text)
        } else if text.hasPrefix("\"file://"), text.hasSuffix(".png\"") {
          let path = text.dropFirst("\"file://".count).dropLast()
          lines.append("    " + (path.contains("/__Snapshots__/") ? "reference: " : "actual:    ") + path)
        } else if text.contains("error:"), !text.contains("/.build/") {
          lines.append("  " + text)
        }
      }
      return Array(lines.prefix(40))
    }
  }
#endif
