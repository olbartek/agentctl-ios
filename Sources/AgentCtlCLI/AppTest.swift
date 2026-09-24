#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation

  /// `app test`: the scenario files, run in the real app on a simulator through its agent bridge, one fresh launch
  /// each — what `test` does headlessly.
  @MainActor
  enum AppTest {
    struct Options {
      var simulator: String
      var latency: Int?
      var build: Bool
      var port: Int
      /// Record the whole run to this `.mp4`, with a chapters file next to it.
      var record: String?
      /// Send the scenario one line at a time, this many seconds apart, so a recording can be followed.
      var stepDelay: Double?
    }

    /// Exit codes (CONTRACT.md §5): 0 when every scenario that ran passed; 1 when one failed; 3 when there was
    /// nothing to run, the app could not be built or launched, or its bridge did not answer.
    static func run(paths: [String], options: Options) async -> Int32 {
      guard let root = Repo.root(), let files = Commands.scenarioFiles(paths) else {
        return RunStatus.internalError.rawValue
      }
      let device: Simulator.Device
      do {
        device = try Simulator(root: root).resolve(options.simulator)
      } catch {
        printError("\(error)")
        return RunStatus.internalError.rawValue
      }
      var recording: Recording?
      if let path = options.record {
        do {
          recording = try Recording.start(device: device, to: URL(fileURLWithPath: path))
        } catch {
          printError("\(error)")
          return RunStatus.internalError.rawValue
        }
      }
      defer { recording?.stop() }

      var results: [Result] = []
      var built = !options.build
      for file in files {
        let name = file.deletingPathExtension().lastPathComponent
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
          results.append(Result(name: name, outcome: .broken("cannot read \(file.path)")))
          print(results[results.count - 1].report)
          continue
        }
        if let reason = AppTestSkip.reason(in: source) {
          results.append(Result(name: name, outcome: .skipped(reason)))
          print(results[results.count - 1].report)
          continue
        }
        recording?.chapter(name)
        let result = await runScenario(name: name, source: source, root: root, device: device, build: !built, options: options)
        built = true
        results.append(result)
        print(result.report)
      }
      print(summary(results))
      if let recording {
        print("recorded \(recording.video.path(percentEncoded: false)) (chapters: \(recording.chaptersFile.lastPathComponent))")
      }
      if results.contains(where: \.isBroken) { return RunStatus.internalError.rawValue }
      return results.contains(where: \.failed) ? RunStatus.failed.rawValue : 0
    }

    /// A fresh launch with no saved session, then the script through the bridge: whole, or a line at a time.
    static func runScenario(
      name: String, source: String, root: URL, device: Simulator.Device, build: Bool, options: Options
    ) async -> Result {
      let clock = ContinuousClock()
      let start = clock.now
      let lines: [ScriptLine]
      do {
        lines = try ScriptParser.parse(source)
      } catch {
        return Result(name: name, outcome: .failed(line: error.line, text: "parse error: \(error.description)"))
      }
      do {
        _ = try await AppCommands.launchApp(
          root: root, seed: nil, simulator: device.udid, latency: options.latency, clearSession: true, build: build,
          port: options.port
        )
      } catch {
        return Result(name: name, outcome: .broken("launch failed: \(error)"))
      }
      let client = BridgeClient(port: options.port)
      // One request for the script, or one per line: the app keeps one runner across requests, so `expect` still
      // sees the calls of the step before it.
      let requests = options.stepDelay == nil ? [source] : lines.map(\.text)
      var body = ""
      var exitCode: Int32 = 0
      for (index, request) in requests.enumerated() {
        if let delay = options.stepDelay, index > 0 {
          try? await Task.sleep(for: .seconds(delay))
        }
        do {
          let response = try await client.send("POST", "/run", body: request)
          body += response.body
          exitCode = response.exitCode
        } catch {
          return Result(name: name, outcome: .broken(Message.bridgeUnreachable(port: options.port, error: error)))
        }
        if exitCode != 0 { break }
      }
      return result(name: name, lines: lines, body: body, exitCode: exitCode, duration: start.duration(to: clock.now))
    }

    /// What one run through the bridge amounts to, from the steps it printed and its exit code.
    static func result(name: String, lines: [ScriptLine], body: String, exitCode: Int32, duration: Duration) -> Result {
      let blocks = stepBlocks(body)
      guard exitCode == 0 else {
        // The failing step is the last one printed, and it ran the script's line with the same index.
        let line = blocks.isEmpty ? nil : lines.indices.contains(blocks.count - 1) ? lines[blocks.count - 1].line : nil
        let error = body.split(separator: "\n").last { $0.hasPrefix("error: ") }.map(String.init)
        return Result(name: name, outcome: .failed(line: line, text: blocks.last ?? error ?? body))
      }
      return Result(name: name, outcome: .passed(steps: blocks.count, duration: duration))
    }

    /// The steps in a text response: each starts at a `> ` line and runs to the next.
    static func stepBlocks(_ body: String) -> [String] {
      var blocks: [[Substring]] = []
      for line in body.split(separator: "\n") {
        if line.hasPrefix("> ") {
          blocks.append([line])
        } else if !blocks.isEmpty, line.hasPrefix(" ") {
          blocks[blocks.count - 1].append(line)
        }
      }
      return blocks.map { $0.joined(separator: "\n") }
    }

    static func summary(_ results: [Result]) -> String {
      let passed = results.filter(\.passed).count
      let failed = results.filter { $0.failed || $0.isBroken }.count
      let skipped = results.filter(\.skipped).count
      return "\(passed) passed, \(failed) failed, \(skipped) skipped"
    }

    struct Result {
      enum Outcome {
        case passed(steps: Int, duration: Duration)
        case failed(line: Int?, text: String)
        case skipped(String)
        /// Not the scenario's fault: the app did not launch, or the file could not be read.
        case broken(String)
      }

      var name: String
      var outcome: Outcome

      var passed: Bool { if case .passed = outcome { true } else { false } }
      var failed: Bool { if case .failed = outcome { true } else { false } }
      var skipped: Bool { if case .skipped = outcome { true } else { false } }
      var isBroken: Bool { if case .broken = outcome { true } else { false } }

      /// `PASS name (N steps, X ms)`, `FAIL name:line` with the failing step, or `SKIP name: reason`: the headless
      /// `test`'s lines, plus skips.
      var report: String {
        switch outcome {
        case let .passed(steps, duration):
          let milliseconds = Int(duration.components.seconds) * 1000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
          return "PASS \(name) (\(steps) steps, \(milliseconds) ms)"
        case let .failed(line, text):
          let lines = text.split(separator: "\n").map { "  \($0)" }
          return (["FAIL \(name)\(line.map { ":\($0)" } ?? "")"] + lines).joined(separator: "\n")
        case let .skipped(reason):
          return "SKIP \(name): \(reason)"
        case let .broken(message):
          return "FAIL \(name)\n  \(message)"
        }
      }
    }

    /// `simctl io recordVideo` for the whole run, and a chapters file with the time each scenario started.
    final class Recording {
      let video: URL
      let chaptersFile: URL
      private let process: Process
      private let started: ContinuousClock.Instant
      private var chapters: [String] = []

      private init(video: URL, process: Process) {
        self.video = video
        self.chaptersFile = video.appendingPathExtension("chapters.txt")
        self.process = process
        self.started = ContinuousClock.now
      }

      /// Starts recording and returns once `simctl` says it has.
      static func start(device: Simulator.Device, to video: URL) throws -> Recording {
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "simctl", "io", device.udid, "recordVideo", "--codec=h264", "--force", video.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // `simctl` prints "Recording started" once frames are being written.
        var output = ""
        let deadline = Date().addingTimeInterval(20)
        while !output.contains("Recording started") {
          guard process.isRunning, Date() < deadline else {
            process.terminate()
            throw AppCtlError("simctl recordVideo did not start: \(output)")
          }
          output += String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        }
        return Recording(video: video, process: process)
      }

      func chapter(_ name: String) {
        chapters.append("\(AppTest.timestamp(started.duration(to: .now))) \(name)")
      }

      /// Stops the recording (`simctl` finishes the file on SIGINT) and writes the chapters.
      func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        process.waitUntilExit()
        try? (chapters.joined(separator: "\n") + "\n").write(to: chaptersFile, atomically: true, encoding: .utf8)
      }
    }

    /// `HH:MM:SS`.
    nonisolated static func timestamp(_ duration: Duration) -> String {
      let seconds = Int(duration.components.seconds)
      return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
  }
#endif
