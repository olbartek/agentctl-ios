#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlTCA
  import Foundation

  /// Finds, builds for and launches the host app on an iOS simulator.
  struct Simulator {
    /// How `xcodebuild` is invoked and what the built app is called, from the host's config.
    static var target: BuildTarget { AgentCtl.runtime.target }
    static var bundleID: String { AgentCtl.runtime.bundleID }

    struct Device: Equatable {
      var udid: String
      var name: String
      var runtime: String
      var version: [Int]
      var isBooted: Bool
      var isBeta: Bool

      var label: String { "\(name) (\(runtime))" }
    }

    let root: URL

    /// A UDID, or a device name. For a name: booted devices first, then released runtimes before betas, then the
    /// newest runtime.
    /// - Parameter runtimeMajor: only consider devices on this iOS major version (e.g. 18).
    func resolve(_ nameOrUDID: String, runtimeMajor: Int? = nil) throws -> Device {
      let devices = try availableDevices().filter { runtimeMajor == nil || $0.version.first == runtimeMajor }
      if let device = devices.first(where: { $0.udid == nameOrUDID }) { return device }
      let matches = devices.filter { $0.name == nameOrUDID }
      guard
        let best = matches.max(by: { lhs, rhs in
          (lhs.isBooted ? 1 : 0, lhs.isBeta ? 0 : 1, lhs.version.lexicographicKey)
            < (rhs.isBooted ? 1 : 0, rhs.isBeta ? 0 : 1, rhs.version.lexicographicKey)
        })
      else {
        let names = Set(devices.map(\.name)).sorted().joined(separator: ", ")
        let runtime = runtimeMajor.map { " on iOS \($0)" } ?? ""
        throw AppCtlError("no available simulator named '\(nameOrUDID)'\(runtime). Available: \(names)")
      }
      return best
    }

    /// Builds the app via XcodeBuildMCP (falling back to xcodebuild) and installs it on `device`, booting it if
    /// needed. ``launch(on:launchArguments:log:)`` then starts it.
    ///
    /// Building and launching are separate steps so the bridge's port can be picked after the build: a build takes
    /// minutes, and a port that was free before it may not be free after it.
    func buildAndInstall(on device: Device, log: URL) throws {
      let app: URL
      if Shell.which("xcodebuildmcp") {
        var arguments: [String: Any] = [
          "scheme": Self.target.scheme,
          "simulatorId": device.udid,
          "extraArgs": ["-skipMacroValidation"],
        ]
        switch Self.target {
        case let .workspace(path, _): arguments["workspacePath"] = root.appending(path: path).path
        case let .project(path, _): arguments["projectPath"] = root.appending(path: path).path
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let status = Shell.run(["xcodebuildmcp", "simulator", "build", "--json", json], in: root, log: log)
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard status == 0, !output.contains("❌") else {
          throw AppCtlError("build failed; log: \(log.path(percentEncoded: false))")
        }
        arguments["platform"] = "iOS Simulator"
        let pathJSON = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let pathOutput = Shell.capture(["xcodebuildmcp", "simulator", "get-app-path", "--json", pathJSON], in: root, timeout: Shell.slow)
        guard let path = Self.appPath(fromGetAppPath: pathOutput) else {
          throw AppCtlError("cannot find the built app in `xcodebuildmcp simulator get-app-path`: \(pathOutput)")
        }
        app = path
      } else {
        let derivedData = Layout(root: root).derivedData
        let status = Shell.run(
          ["xcodebuild"] + Self.target.xcodebuildArguments + [
            "-destination", "id=\(device.udid)", "-derivedDataPath", derivedData.path, "-skipMacroValidation", "-quiet",
            "build",
          ],
          in: root,
          log: log
        )
        guard status == 0 else { throw AppCtlError("xcodebuild failed; log: \(log.path(percentEncoded: false))") }
        app = derivedData.appending(path: "Build/Products/Debug-iphonesimulator/\(Self.target.scheme).app")
      }
      _ = Shell.run(["xcrun", "simctl", "boot", device.udid], in: root, log: log, append: true, timeout: Shell.slow)
      guard Shell.run(["xcrun", "simctl", "install", device.udid, app.path], in: root, log: log, append: true, timeout: Shell.slow) == 0 else {
        throw AppCtlError("simctl install failed; log: \(log.path(percentEncoded: false))")
      }
    }

    /// The `.app` in `xcodebuildmcp simulator get-app-path`'s report: the line `App Path: <path>`, `~` expanded.
    static func appPath(fromGetAppPath output: String) -> URL? {
      let marker = "App Path: "
      guard let line = output.split(separator: "\n").first(where: { $0.contains(marker) }),
        let range = line.range(of: marker)
      else { return nil }
      let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
      guard path.hasSuffix(".app") else { return nil }
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Stops the app if it is running. A device where it is not running is not an error.
    func terminate(on device: Device, log: URL) {
      _ = Shell.run(["xcrun", "simctl", "terminate", device.udid, Self.bundleID], in: root, log: log, timeout: Shell.quick)
    }

    /// Relaunches the installed app with launch arguments, without building.
    func launch(on device: Device, launchArguments: [String], log: URL) throws {
      _ = Shell.run(
        ["xcrun", "simctl", "terminate", device.udid, Self.bundleID], in: root, log: log, append: true, timeout: Shell.quick
      )
      let status = Shell.run(
        ["xcrun", "simctl", "launch", device.udid, Self.bundleID] + launchArguments,
        in: root,
        log: log,
        append: true,
        timeout: Shell.quick
      )
      guard status == 0 else { throw AppCtlError("simctl launch failed; log: \(log.path(percentEncoded: false))") }
    }

    func screenshot(on device: Device, to file: URL, log: URL) throws {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard Shell.run(["xcrun", "simctl", "io", device.udid, "screenshot", file.path], in: root, log: log, timeout: Shell.quick) == 0 else {
        throw AppCtlError("screenshot failed; log: \(log.path(percentEncoded: false))")
      }
    }

    /// Starts `simctl io recordVideo` detached, so it outlives the CLI. `started` gets its pid as soon as it runs,
    /// before it has begun recording, so the caller can record it even if this CLI is interrupted while it waits;
    /// this returns once `simctl` says it is recording. `app record stop` ends it with SIGINT, which makes `simctl`
    /// finish the file.
    func startRecording(on device: Device, to video: URL, log: URL, started: (Int32) throws -> Void) throws {
      try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let simctl = Shell.capture(["xcrun", "-f", "simctl"], in: root, timeout: Shell.quick).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !simctl.isEmpty else { throw AppCtlError("cannot find simctl (xcrun -f simctl)") }
      let handle = try FileHandle(forWritingTo: log)
      defer { try? handle.close() }
      let process = Process()
      // `nohup` execs simctl in place, so the pid is simctl's own and its command line names the file; a hangup of
      // the terminal that started it does not stop it.
      process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
      process.arguments = [simctl, "io", device.udid, "recordVideo", "--codec=h264", "--force", video.path]
      process.standardOutput = handle
      process.standardError = handle
      process.standardInput = FileHandle.nullDevice
      try process.run()
      do {
        try started(process.processIdentifier)
      } catch {
        process.terminate()
        throw error
      }
      let deadline = Date().addingTimeInterval(20)
      while !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Recording started") {
        guard process.isRunning, Date() < deadline else {
          process.terminate()
          throw AppCtlError("simctl recordVideo did not start; log: \(log.path(percentEncoded: false))")
        }
        Thread.sleep(forTimeInterval: 0.1)
      }
    }

    /// A clean status bar for screenshots (9:41 in the simulator's own time format, full signal, a full battery that is
    /// not charging), or the simulator's own again.
    func statusBar(clean: Bool, on device: Device, log: URL) throws {
      let arguments =
        clean
        ? [
          "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
          "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100",
        ]
        : ["clear"]
      guard Shell.run(["xcrun", "simctl", "status_bar", device.udid] + arguments, in: root, log: log, timeout: Shell.quick) == 0 else {
        throw AppCtlError("simctl status_bar failed (is the simulator booted?); log: \(log.path(percentEncoded: false))")
      }
    }

    /// The installed app's bundle, or `nil` when it is not installed.
    func installedApp(on device: Device) -> URL? {
      let path = Shell.capture(["xcrun", "simctl", "get_app_container", device.udid, Self.bundleID, "app"], in: root)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }

    private func availableDevices() throws -> [Device] {
      let runtimes = try simctlJSON(["runtimes"])["runtimes"] as? [[String: Any]] ?? []
      var betaRuntimes: Set<String> = []
      for runtime in runtimes {
        if let identifier = runtime["identifier"] as? String, let build = runtime["buildversion"] as? String,
          build.last?.isLowercase == true
        {
          betaRuntimes.insert(identifier)
        }
      }
      let byRuntime = try simctlJSON(["devices", "available"])["devices"] as? [String: [[String: Any]]] ?? [:]
      return byRuntime.flatMap { runtime, devices in
        let version = runtime.split(separator: ".").last.map { $0.split(separator: "-").dropFirst().compactMap { Int($0) } } ?? []
        let runtimeName = "iOS " + version.map(String.init).joined(separator: ".")
        return devices.compactMap { device -> Device? in
          guard runtime.contains("iOS"), let udid = device["udid"] as? String, let name = device["name"] as? String else {
            return nil
          }
          return Device(
            udid: udid,
            name: name,
            runtime: runtimeName,
            version: version,
            isBooted: device["state"] as? String == "Booted",
            isBeta: betaRuntimes.contains(runtime)
          )
        }
      }
    }

    private func simctlJSON(_ arguments: [String]) throws -> [String: Any] {
      let (output, finished) = Shell.captureResult(["xcrun", "simctl", "list"] + arguments + ["-j"], in: root)
      guard finished else { throw AppCtlError(Message.simctlDidNotAnswer(["list"] + arguments)) }
      guard let data = output.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw AppCtlError("cannot read `xcrun simctl list \(arguments.joined(separator: " "))`") }
      return object
    }
  }

  extension [Int] {
    /// A comparable key for version numbers such as [26, 5].
    fileprivate var lexicographicKey: Int {
      prefix(3).enumerated().reduce(0) { $0 + $1.element * [1_000_000, 1_000, 1][$1.offset] }
    }
  }

  /// Talks to the agent bridge (AgentCtlBridge) in the running app over loopback HTTP.
  struct BridgeClient {
    let port: Int

    struct Response {
      var status: Int
      var body: String
      var exitCode: Int32
      /// `X-Appctl-App`: the bundle ID of the app that answered, if it says.
      var app: String?
    }

    func send(_ method: String, _ path: String, body: String? = nil, timeout: TimeInterval = 60) async throws -> Response {
      guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw AppCtlError("bad path \(path)") }
      var request = URLRequest(url: url, timeoutInterval: timeout)
      request.httpMethod = method
      request.httpBody = body.map { Data($0.utf8) }
      let (data, response) = try await URLSession.shared.data(for: request)
      let http = response as? HTTPURLResponse
      return Response(
        status: http?.statusCode ?? 0,
        body: String(decoding: data, as: UTF8.self),
        exitCode: Int32(http?.value(forHTTPHeaderField: "X-Appctl-Exit") ?? "") ?? 3,
        app: http?.value(forHTTPHeaderField: "X-Appctl-App")
      )
    }

    /// Polls `GET /snapshot` until the bridge answers, and returns its answer.
    func waitUntilReady(timeout: Duration = .seconds(60)) async throws -> Response {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if let response = try? await send("GET", "/snapshot", timeout: 2), response.status == 200 {
          return response
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw AppCtlError("the app's agent bridge did not answer on 127.0.0.1:\(port) within \(timeout)")
    }
  }

  struct AppCtlError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }

#endif
