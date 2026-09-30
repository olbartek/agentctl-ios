#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AVFoundation
  import AgentCtlTCA
  import Foundation

  /// `app screenshot`, `app record start|stop`, `app statusbar clean|reset` and `app info`: the simulator itself, for
  /// demos and screenshots. None of them needs the app's bridge.
  ///
  /// Each acts on `--sim`, else the simulator the last launch recorded in `bridge.json`, else the config's simulator.
  enum DeviceCommands {
    static func screenshot(to path: String, simulator: String?) -> Int32 {
      run(simulator) { root, sim, device in
        let file = URL(fileURLWithPath: path).standardizedFileURL
        try sim.screenshot(on: device, to: file, log: Layout(root: root).logs.appending(path: "app-screenshot.log"))
        print("saved \(file.path(percentEncoded: false)) (\(device.label) [\(device.udid)])")
      }
    }

    static func recordStart(to path: String, simulator: String?) -> Int32 {
      run(simulator) { root, sim, device in
        if let running = try RecordingState.read(in: root), RecordingState.isRunning(running) {
          throw AppCtlError(Message.recordingRunning(running))
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let pid = try sim.startRecording(on: device, to: file, log: Layout(root: root).logs.appending(path: "app-record.log"))
        try RecordingState(device: device.udid, file: file.path(percentEncoded: false), pid: Int(pid), startedAt: Date())
          .write(in: root)
        print("recording \(file.path(percentEncoded: false)) (\(device.label) [\(device.udid)]); stop with \(help.invocation) app record stop")
      }
    }

    static func recordStop() -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      do {
        guard let state = try RecordingState.read(in: root) else { throw AppCtlError(Message.noRecording) }
        guard RecordingState.isRunning(state) else {
          try? FileManager.default.removeItem(at: RecordingState.file(in: root))
          throw AppCtlError(Message.recordingGone(state))
        }
        // simctl finishes the file on SIGINT.
        kill(pid_t(state.pid), SIGINT)
        let deadline = Date().addingTimeInterval(30)
        while kill(pid_t(state.pid), 0) == 0, Date() < deadline {
          Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: RecordingState.file(in: root))
        let seconds = Self.duration(of: URL(fileURLWithPath: state.file))
        print("recorded \(state.file) (\(String(format: "%.1f", seconds))s)")
        return 0
      } catch {
        return AppCommands.fail(error)
      }
    }

    static func statusbar(clean: Bool, simulator: String?) -> Int32 {
      run(simulator) { root, sim, device in
        try sim.statusBar(clean: clean, on: device, log: Layout(root: root).logs.appending(path: "app-statusbar.log"))
        print("status bar \(clean ? "clean" : "reset") on \(device.label) [\(device.udid)]")
      }
    }

    static func info(simulator: String?) -> Int32 {
      run(simulator) { _, sim, device in
        guard let app = sim.installedApp(on: device) else {
          throw AppCtlError(Message.notInstalled(on: device))
        }
        let plist = NSDictionary(contentsOf: app.appending(path: "Info.plist")) as? [String: Any] ?? [:]
        let info = AppInfo(
          appId: Simulator.bundleID,
          build: plist["CFBundleVersion"] as? String ?? "",
          device: device.udid,
          platform: "ios",
          version: plist["CFBundleShortVersionString"] as? String ?? ""
        )
        print(try info.encoded())
      }
    }

    /// The simulator an L2 command acts on: `--sim`, else the last launch's (when it was an iOS one), else the
    /// config's.
    static func device(_ simulator: String?, root: URL, sim: Simulator) throws -> Simulator.Device {
      if let simulator { return try sim.resolve(simulator) }
      if let state = try LaunchState.read(in: root), state.platform == "ios" { return try sim.resolve(state.device) }
      return try sim.resolve(AgentCtl.runtime.simulatorName)
    }

    private static func run(_ simulator: String?, _ body: (URL, Simulator, Simulator.Device) throws -> Void) -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      do {
        let sim = Simulator(root: root)
        try body(root, sim, try device(simulator, root: root, sim: sim))
        return 0
      } catch {
        return AppCommands.fail(error)
      }
    }

    static func duration(of video: URL) -> Double {
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var seconds = 0.0
      Task {
        if let time = try? await AVURLAsset(url: video).load(.duration) { seconds = time.seconds }
        semaphore.signal()
      }
      semaphore.wait()
      return seconds.isFinite ? seconds : 0
    }
  }

  /// `app info`'s line: compact JSON with sorted keys, as agentctl-android prints it.
  struct AppInfo: Codable, Equatable {
    var appId: String
    var build: String
    var device: String
    var platform: String
    var version: String

    func encoded() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
  }

  /// `<outputPath>/record.json`: the recorder `app record start` left running, for `app record stop`. The same form
  /// as `bridge.json`.
  struct RecordingState: Codable, Equatable {
    var device: String
    var file: String
    var pid: Int
    var platform: String
    var startedAt: String

    static let fileName = "record.json"

    init(device: String, file: String, pid: Int, platform: String = "ios", startedAt: Date) {
      self.device = device
      self.file = file
      self.pid = pid
      self.platform = platform
      self.startedAt = LaunchState.timestamp(startedAt)
    }

    static func file(in root: URL) -> URL {
      Layout(root: root).output.appending(path: fileName)
    }

    func encoded() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    func write(in root: URL) throws {
      let file = Self.file(in: root)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoded().write(to: file, atomically: true, encoding: .utf8)
    }

    static func read(in root: URL) throws -> RecordingState? {
      let file = file(in: root)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      do {
        return try JSONDecoder().decode(RecordingState.self, from: Data(contentsOf: file))
      } catch {
        throw AppCtlError("cannot read \(AgentCtl.runtime.outputPath)/\(fileName): \(error)")
      }
    }

    /// Whether the recorder is still running, and is ours: its process is alive and its command line names the file.
    /// A pid the system has since reused for something else does not count.
    static func isRunning(_ state: RecordingState) -> Bool {
      guard state.pid > 0, kill(pid_t(state.pid), 0) == 0 else { return false }
      return Shell.capture(["ps", "-o", "command=", "-p", String(state.pid)], in: URL(fileURLWithPath: "/"))
        .contains(state.file)
    }
  }
#endif
