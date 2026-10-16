#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation

  /// The implementations behind the subcommands. They run on the main actor with the main serial executor,
  /// which makes every headless run deterministic.
  @MainActor
  enum Commands {
    static func run(script: String, sessionPath: String?, diff: Bool, json: Bool) async -> Int32 {
      Deterministic.isEnabled = true
      let runner = AgentCtl.runtime.makeRunner()
      let launch = await runner.launch()
      // A launch that did not settle fails the run before the script (or a session replay) starts.
      guard launch.status == .ok else {
        print(json ? StepFormatter.json([launch.step]) : StepFormatter.text(launch.step))
        return launch.status.rawValue
      }
      var steps: [StepRecord] = []
      if let sessionPath {
        guard let saved = Session.read(sessionPath) else { return RunStatus.internalError.rawValue }
        let replay = (try? await runner.run(saved)) ?? .cancelled
        guard replay.status == .ok else {
          printError("session replay of \(sessionPath) failed at \(replay.failedLine?.text ?? "a line"): \(replay.message ?? replay.steps.last?.message ?? "")")
          return RunStatus.failed.rawValue
        }
      } else {
        steps.append(launch.step)
      }
      runner.recordsDiff = diff
      let result = (try? await runner.run(script)) ?? .cancelled
      steps += result.steps
      if json {
        print(StepFormatter.json(steps))
      } else if !steps.isEmpty {
        print(StepFormatter.text(steps))
      }
      if let message = result.message {
        printError(message)
      }
      // A session that cannot be saved is an environment failure (3), whatever the script's own code.
      if let sessionPath, !Session.write(result.executed, to: sessionPath) {
        return RunStatus.internalError.rawValue
      }
      return result.status.rawValue
    }

    static func state(sessionPath: String?) async -> Int32 {
      Deterministic.isEnabled = true
      let runner = AgentCtl.runtime.makeRunner()
      let launch = await runner.launch()
      guard launch.status == .ok else {
        printError("the app did not settle at launch\n" + StepFormatter.text(launch.step))
        return launch.status.rawValue
      }
      if let sessionPath {
        guard let saved = Session.read(sessionPath) else { return RunStatus.internalError.rawValue }
        let replay = (try? await runner.run(saved)) ?? .cancelled
        guard replay.status == .ok else {
          printError("session replay of \(sessionPath) failed")
          return RunStatus.failed.rawValue
        }
      }
      print(runner.stateDump)
      return 0
    }

    static func screens() {
      print(
        ScreensRenderer.render(
          AgentCtl.runtime.screens, mockExample: AgentCtl.runtime.docsText.mockExample,
          device: AgentCtl.runtime.deviceSurface
        )
      )
    }

    /// The generated command reference as it should be, rendered from the config.
    static var docsMarkdown: String {
      DocsRenderer.render(
        screens: AgentCtl.runtime.screens, mockMethods: AgentCtl.runtime.mockMethods, text: AgentCtl.runtime.docsText,
        device: AgentCtl.runtime.deviceSurface
      )
    }

    static func docs(check: Bool) -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      let path = AgentCtl.runtime.docsPath
      let file = root.appending(path: path)
      let generated = docsMarkdown
      let existing = try? String(contentsOf: file, encoding: .utf8)
      if check {
        guard existing == generated else {
          print(Message.staleDocs)
          return 1
        }
        print("\(path) is up to date.")
        return 0
      }
      do {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try generated.write(to: file, atomically: true, encoding: .utf8)
      } catch {
        printError("cannot write \(file.path): \(error)")
        return RunStatus.internalError.rawValue
      }
      print(existing == generated ? "\(path) was already up to date." : "Wrote \(path).")
      return 0
    }

    /// Exit codes (CONTRACT.md §5): 0 when every scenario passed; 1 when one failed; 3 when there was nothing to
    /// run or a file could not be read — no scenario files where the config says they are, a scenario file named
    /// on the command line that does not exist, or no repo root to look in.
    static func test(paths: [String]) async -> Int32 {
      Deterministic.isEnabled = true
      guard let files = scenarioFiles(paths) else { return RunStatus.internalError.rawValue }
      let results = await AgentCtl.runtime.runScenarios(files)
      for result in results {
        print(result.report)
      }
      let failed = results.filter { !$0.passed }.count
      print("\(results.count - failed) passed, \(failed) failed")
      if results.contains(where: { $0.status == .internalError }) {
        return RunStatus.internalError.rawValue
      }
      return failed == 0 ? 0 : RunStatus.failed.rawValue
    }

    static func snapshots(record: Bool, simulator: String) -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      let result = SnapshotRunner.run(root: root, simulator: simulator, record: record)
      let device = result.device.map { " on \($0.label)" } ?? ""
      if record {
        print("\(result.ok ? "recorded" : "FAILED to record") snapshots\(device)")
      } else {
        print("\(result.ok ? "ok" : "FAIL") \(result.tests) snapshot tests\(device)")
      }
      result.details.forEach { print($0) }
      if record, result.ok {
        print("Review the changes: git status --short \(SnapshotRunner.testDirectories.joined(separator: " "))")
      }
      return result.status.rawValue
    }

    static func check(ui: Bool, simulator: String) async -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      let ladder = Ladder(root: root, ui: ui, simulator: simulator)
      return await ladder.run()
    }

    // MARK: - Shared helpers

    /// The files named on the command line, or else every scenario in the config's `scenariosPath`. `nil`, with
    /// the reason printed, when there is no repo root or that directory holds no scenario files: a run that
    /// checked nothing must not report success.
    static func scenarioFiles(_ paths: [String]) -> [URL]? {
      guard paths.isEmpty else {
        return paths.map { URL(fileURLWithPath: $0) }
      }
      guard let root = Repo.root() else { return nil }
      let directory = root.appending(path: AgentCtl.runtime.scenariosPath)
      let files = ScenarioRunner.files(in: directory)
      guard !files.isEmpty else {
        printError(Message.noScenarios(in: directory))
        return nil
      }
      return files
    }
  }

  /// `--session` files: one command per line, replayed before each run.
  ///
  /// A file that does not exist yet is an empty session, which the first run creates. One that exists but cannot be
  /// read (a directory included), or cannot be written, is an environment failure: ``read(_:)`` and ``write(_:to:)``
  /// print `error: cannot read <path>: <reason>` or `error: cannot write <path>: <reason>`, `<path>` as given.
  enum Session {
    /// The saved commands, `""` when there is no file yet, or `nil` (with the error printed) when it cannot be read.
    static func read(_ path: String) -> String? {
      do {
        return try load(path)
      } catch {
        printError("cannot read \(path): \(reason(error))")
        return nil
      }
    }

    static func load(_ path: String) throws -> String {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "" }
      // Foundation reports a directory without its errno; read(2) would say EISDIR.
      if isDirectory.boolValue { throw POSIXError(.EISDIR) }
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      guard let text = String(data: data, encoding: .utf8) else { throw NotUTF8() }
      return text
    }

    /// A session file whose bytes are not UTF-8: it cannot be read, as agentctl-android says it.
    struct NotUTF8: Error, CustomStringConvertible {
      var description: String { "not valid UTF-8" }
    }

    /// Why a read or write failed, without the path: the POSIX `strerror` text of the underlying errno
    /// ("Permission denied", "Is a directory"), as agentctl-android prints it; Foundation's own description when
    /// there is no errno, since that one names the file.
    static func reason(_ error: any Error) -> String {
      if let error = error as? NotUTF8 { return error.description }
      var current: NSError? = error as NSError
      while let nsError = current {
        if nsError.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(nsError.code))) }
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      return error.localizedDescription
    }

    /// Appends `lines`, creating the file (and its directory) if needed. `false`, with the error printed, when it
    /// cannot be written.
    static func write(_ lines: [ScriptLine], to path: String) -> Bool {
      do {
        try append(lines, to: path)
        return true
      } catch {
        printError("cannot write \(path): \(reason(error))")
        return false
      }
    }

    static func append(_ lines: [ScriptLine], to path: String) throws {
      let url = URL(fileURLWithPath: path)
      let text = lines.isEmpty ? "" : lines.map(\.text).joined(separator: "\n") + "\n"
      guard FileManager.default.fileExists(atPath: path) else {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return
      }
      guard !lines.isEmpty else { return }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
    }
  }

  enum Repo {
    /// `$APPCTL_ROOT` (set by the wrapper), or the nearest ancestor of the working directory containing the
    /// config's root marker — by default its build target (the `.xcworkspace` or `.xcodeproj`).
    static func root() -> URL? {
      guard let root = find() else {
        printError("cannot find the repo root (no \(AgentCtl.runtime.rootMarker) above \(FileManager.default.currentDirectoryPath))")
        return nil
      }
      return root
    }

    /// ``root()`` without the error message, for a command that also works outside the repo.
    static func find() -> URL? {
      if let path = ProcessInfo.processInfo.environment["APPCTL_ROOT"], !path.isEmpty {
        return URL(fileURLWithPath: path)
      }
      return RepoRoot.find(
        marker: AgentCtl.runtime.rootMarker, from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      )
    }
  }

  /// The messages that name the CLI itself. They spell it with the host's own invocation, never `./appctl`:
  /// a host's users are told to run a command that exists in their repo.
  enum Message {
    /// A request to the bridge that failed. A script that ran past its limit reached the bridge, so it says that
    /// instead.
    static func bridgeUnreachable(port: Int, error: any Error) -> String {
      if let timedOut = error as? BridgeClient.ScriptTimedOut { return timedOut.description }
      return "cannot reach the app's agent bridge on 127.0.0.1:\(port) (is the app running? \(help.invocation) app launch): "
        + "\(error)"
    }

    /// ``bridgeUnreachable(port:error:)``, saying where the port came from when the last launch recorded it: that
    /// app may have quit since.
    static func bridgeUnreachable(port: Int, source: BridgePort.Source, error: any Error) -> String {
      guard case let .launchState(state) = source, !(error is BridgeClient.ScriptTimedOut) else {
        return bridgeUnreachable(port: port, error: error)
      }
      return bridgeUnreachable(port: port, error: error)
        + "; the port is from \(LaunchState.relativePath) (launched \(state.launchedAt) on \(state.device)), "
        + "which is stale once that app has quit: relaunch with \(help.invocation) app launch"
    }

    /// A launch whose bridge answered as another app, or as none: another process holds the port.
    /// Without the header, the app may also be an installed one from before it (`--no-build`).
    static func anotherApp(port: Int, answeredAs answer: BridgeIdentity) -> String {
      let missing = answer.app == nil ? "X-Appctl-App" : answer.platform == nil ? "X-Appctl-Platform" : nil
      return "the app's agent bridge on 127.0.0.1:\(port) answers as \(answer), not \(BridgeIdentity.ours): another "
        + "app holds that port; pass --port or set \(BridgePort.environmentVariable)"
        + (missing.map { " (or the installed app predates \($0): launch without --no-build)" } ?? "")
    }

    /// A launch whose bridge never answered while something else listens on its port.
    static func portHeld(port: Int) -> String {
      "the app's agent bridge could not listen on 127.0.0.1:\(port): another process holds that port; pass --port or "
        + "set \(BridgePort.environmentVariable)"
    }

    /// A port from the launch state that another app now answers on.
    static func anotherApp(port: Int, answeredAs answer: BridgeIdentity, recorded state: LaunchState) -> String {
      "the app's agent bridge on 127.0.0.1:\(port) answers as \(answer), not "
        + "\(BridgeIdentity(app: state.appId, platform: state.platform)) from \(LaunchState.relativePath), which is stale: "
        + "relaunch with \(help.invocation) app launch"
    }

    /// A scenario's response that another app sent: its output is not the app's, and the scenario did not run.
    static func anotherAppAnswered(port: Int, answeredAs answer: BridgeIdentity) -> String {
      "the app's agent bridge on 127.0.0.1:\(port) answers as \(answer), not \(BridgeIdentity.ours): another app "
        + "took the port during the run"
    }

    static func recordingRunning(_ state: RecordingState) -> String {
      "a recording is already running: \(state.file) (started \(state.startedAt)); stop it with \(help.invocation) app record stop"
    }

    static var noRecording: String {
      "no recording to stop (no \(AgentCtl.runtime.outputPath)/\(RecordingState.fileName))"
    }

    static func recordingGone(_ state: RecordingState) -> String {
      "the recording of \(state.file) is no longer running"
    }

    static func recorderDidNotFinish(_ state: RecordingState) -> String {
      "the recorder of \(state.file) did not finish within 30 s; try \(help.invocation) app record stop again"
    }

    static func recordingNotWritten(_ state: RecordingState) -> String {
      "the recording \(state.file) was not written; see \(AgentCtl.runtime.outputPath)/logs/app-record.log"
    }

    /// The recording is there, but its last frame could not be made to last until the end (``RecordedVideo``).
    static func recordingNotHeld(_ file: String, _ error: any Error) -> String {
      "the recording \(file) ends at its last screen change, not at stop: \(error)"
    }

    static func notBooted(_ device: Simulator.Device) -> String {
      "\(device.label) [\(device.udid)] is not booted; boot it, or run \(help.invocation) app launch"
    }

    /// Several simulators could be meant. `runtime` is the runtime filter, if any (" on iOS 18"). The same form as
    /// agentctl-android's, with `--device <serial>` there.
    static func ambiguousSimulator(_ name: String, runtime: String, _ candidates: [Simulator.Device]) -> String {
      (["several simulators are named '\(name)'\(runtime); pass --sim <UDID>:"]
        + candidates.map { "  \($0.udid)  \($0.label)" }).joined(separator: "\n")
    }

    static func pickedNewestSimulator(_ name: String, count: Int, _ device: Simulator.Device) -> String {
      "note: \(count) simulators are named '\(name)'; using \(device.label) [\(device.udid)], the newest runtime; "
        + "pass --sim <UDID> to choose"
    }

    static func bootFailed(_ device: Simulator.Device, log: URL) -> String {
      "\(device.label) [\(device.udid)] did not boot; log: \(log.path(percentEncoded: false))"
    }

    /// `app test --record` when the recorder left no video, or an empty one: the run's result stands, the video does not.
    static var nothingRecorded: String {
      "warning: nothing was recorded; see \(AgentCtl.runtime.outputPath)/logs/app-test-record.log"
    }

    static func notInstalled(on device: Simulator.Device) -> String {
      "\(Simulator.bundleID) is not installed on \(device.label) [\(device.udid)]; run \(help.invocation) app launch"
    }

    /// `simctl` hanging rather than failing: CoreSimulator is wedged, which a restart of it clears.
    static func simctlDidNotAnswer(_ arguments: [String]) -> String {
      "xcrun simctl \(arguments.joined(separator: " ")) did not answer within \(Int(Shell.quick)) s; CoreSimulator may be "
        + "stuck: quit Simulator and run 'xcrun simctl shutdown all', or restart the Mac"
    }

    static func badPortVariable(_ value: String) -> String {
      "\(BridgePort.environmentVariable) is not a port: '\(value)' (expected 1-65535)"
    }

    static var noFreePort: String {
      "no free port for the app's agent bridge in \(BridgePort.scanned.lowerBound)-\(BridgePort.scanned.upperBound): "
        + "pass --port or set \(BridgePort.environmentVariable)"
    }

    static func unreadableLaunchState(error: any Error) -> String {
      "cannot read \(LaunchState.relativePath): \(error); relaunch with \(help.invocation) app launch, or pass --port"
    }

    /// `test` and L2 with nothing to run. Zero scenarios passing is not a pass.
    static func noScenarios(in directory: URL) -> String {
      "no scenario files (*.appctl) in \(directory.path(percentEncoded: false)): check the config's scenariosPath, "
        + "or name the files to run"
    }

    static var staleDocs: String {
      "\(AgentCtl.runtime.docsPath) is stale. Run \(help.invocation) docs."
    }

    /// The `check` ladder's one-column form of ``staleDocs``.
    static var staleDocsDetail: String {
      "stale: run \(help.invocation) docs"
    }
  }

  func printError(_ message: String) {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
  }
#endif
