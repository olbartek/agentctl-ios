#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation

  /// The implementations behind the subcommands. They run on the main actor with the main serial executor,
  /// which makes every headless run deterministic.
  @MainActor
  enum Commands {
    static func run(script: String, sessionPath: String?, diff: Bool, json: Bool) async -> Int32 {
      Deterministic.isEnabled = true
      let runner = AgentCtl.runtime.makeRunner()
      let launch = await runner.launch()
      var steps: [StepRecord] = []
      if let sessionPath {
        let replay = await runner.run(Session.load(sessionPath))
        guard replay.status == .ok else {
          printError("session replay of \(sessionPath) failed at \(replay.failedLine?.text ?? "a line"): \(replay.message ?? replay.steps.last?.message ?? "")")
          return RunStatus.failed.rawValue
        }
      } else {
        steps.append(launch)
      }
      runner.recordsDiff = diff
      let result = await runner.run(script)
      steps += result.steps
      if json {
        print(StepFormatter.json(steps))
      } else if !steps.isEmpty {
        print(StepFormatter.text(steps))
      }
      if let message = result.message {
        printError(message)
      }
      if let sessionPath {
        Session.append(result.executed, to: sessionPath)
      }
      return result.status.rawValue
    }

    static func state(sessionPath: String?) async -> Int32 {
      Deterministic.isEnabled = true
      let runner = AgentCtl.runtime.makeRunner()
      _ = await runner.launch()
      if let sessionPath {
        let replay = await runner.run(Session.load(sessionPath))
        guard replay.status == .ok else {
          printError("session replay of \(sessionPath) failed")
          return RunStatus.failed.rawValue
        }
      }
      print(runner.stateDump)
      return 0
    }

    static func screens() {
      print(ScreensRenderer.render(AgentCtl.runtime.screens))
    }

    /// `docs/agent-commands.md` as it should be, rendered from the config.
    static var docsMarkdown: String {
      DocsRenderer.render(
        screens: AgentCtl.runtime.screens,
        runtimeCommands: AgentRegistry.runtimeCommands,
        mockMethods: AgentCtl.runtime.mockMethods,
        text: AgentCtl.runtime.docsText
      )
    }

    static func docs(check: Bool) -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      let file = root.appending(path: "docs/agent-commands.md")
      let generated = docsMarkdown
      let existing = try? String(contentsOf: file, encoding: .utf8)
      if check {
        guard existing == generated else {
          print(Message.staleDocs)
          return 1
        }
        print("docs/agent-commands.md is up to date.")
        return 0
      }
      do {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try generated.write(to: file, atomically: true, encoding: .utf8)
      } catch {
        printError("cannot write \(file.path): \(error)")
        return RunStatus.internalError.rawValue
      }
      print(existing == generated ? "docs/agent-commands.md was already up to date." : "Wrote docs/agent-commands.md.")
      return 0
    }

    static func test(paths: [String]) async -> Int32 {
      Deterministic.isEnabled = true
      guard let files = scenarioFiles(paths) else { return RunStatus.usage.rawValue }
      let results = await AgentCtl.runtime.runScenarios(files)
      for result in results {
        print(result.report)
      }
      let failed = results.filter { !$0.passed }.count
      print("\(results.count - failed) passed, \(failed) failed")
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
        print("Review the changes: git status --short Packages/*/Tests/*SnapshotTests")
      }
      return result.ok ? 0 : 1
    }

    static func check(ui: Bool, simulator: String) async -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      let ladder = Ladder(root: root, ui: ui, simulator: simulator)
      return await ladder.run()
    }

    // MARK: - Shared helpers

    static func scenarioFiles(_ paths: [String]) -> [URL]? {
      guard paths.isEmpty else {
        return paths.map { URL(fileURLWithPath: $0) }
      }
      guard let root = Repo.root() else { return nil }
      return ScenarioRunner.files(in: root.appending(path: AgentCtl.runtime.scenariosPath))
    }
  }

  /// `--session` files: one command per line, replayed before each run.
  enum Session {
    static func load(_ path: String) -> String {
      (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    static func append(_ lines: [ScriptLine], to path: String) {
      guard !lines.isEmpty else {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        return
      }
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let text = lines.map(\.text).joined(separator: "\n") + "\n"
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
      } else {
        try? text.write(to: url, atomically: true, encoding: .utf8)
      }
    }
  }

  enum Repo {
    /// `$APPCTL_ROOT` (set by the wrapper), or the nearest ancestor of the working directory containing the
    /// config's root marker — by default its build target (the `.xcworkspace` or `.xcodeproj`).
    static func root() -> URL? {
      if let path = ProcessInfo.processInfo.environment["APPCTL_ROOT"], !path.isEmpty {
        return URL(fileURLWithPath: path)
      }
      let marker = AgentCtl.runtime.rootMarker
      var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appending(path: marker).path) {
          return directory
        }
        directory.deleteLastPathComponent()
      }
      printError("cannot find the repo root (no \(marker) above \(FileManager.default.currentDirectoryPath))")
      return nil
    }
  }

  /// The messages that name the CLI itself. They spell it with the host's own invocation, never `./appctl`:
  /// a host's users are told to run a command that exists in their repo.
  enum Message {
    static func bridgeUnreachable(port: Int, error: any Error) -> String {
      "cannot reach AgentBridge on 127.0.0.1:\(port) (is the app running? \(help.invocation) app launch): \(error)"
    }

    static var staleDocs: String {
      "docs/agent-commands.md is stale. Run \(help.invocation) docs."
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
