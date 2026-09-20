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

  /// Builds and runs the app via XcodeBuildMCP (falling back to xcodebuild + simctl), with launch arguments.
  func buildAndRun(on device: Device, launchArguments: [String], log: URL) throws {
    if Shell.which("xcodebuildmcp") {
      var arguments: [String: Any] = [
        "scheme": Self.target.scheme,
        "simulatorId": device.udid,
        "extraArgs": ["-skipMacroValidation"],
        "launchArgs": launchArguments,
      ]
      switch Self.target {
      case let .workspace(path, _): arguments["workspacePath"] = root.appending(path: path).path
      case let .project(path, _): arguments["projectPath"] = root.appending(path: path).path
      }
      let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
      let status = Shell.run(["xcodebuildmcp", "simulator", "build-and-run", "--json", json], in: root, log: log)
      let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      guard status == 0, !output.contains("❌") else {
        throw AppCtlError("build-and-run failed; log: \(log.path(percentEncoded: false))")
      }
    } else {
      let derivedData = root.appending(path: ".appctl/DerivedData")
      let status = Shell.run(
        ["xcodebuild"] + Self.target.xcodebuildArguments + [
          "-destination", "id=\(device.udid)", "-derivedDataPath", derivedData.path, "-skipMacroValidation", "-quiet",
          "build",
        ],
        in: root,
        log: log
      )
      guard status == 0 else { throw AppCtlError("xcodebuild failed; log: \(log.path(percentEncoded: false))") }
      let app = derivedData.appending(path: "Build/Products/Debug-iphonesimulator/\(Self.target.scheme).app")
      _ = Shell.run(["xcrun", "simctl", "boot", device.udid], in: root, log: log, append: true)
      guard Shell.run(["xcrun", "simctl", "install", device.udid, app.path], in: root, log: log, append: true) == 0 else {
        throw AppCtlError("simctl install failed; log: \(log.path(percentEncoded: false))")
      }
      try launch(on: device, launchArguments: launchArguments, log: log)
    }
  }

  /// Relaunches the installed app with launch arguments, without building.
  func launch(on device: Device, launchArguments: [String], log: URL) throws {
    _ = Shell.run(["xcrun", "simctl", "terminate", device.udid, Self.bundleID], in: root, log: log)
    let status = Shell.run(
      ["xcrun", "simctl", "launch", device.udid, Self.bundleID] + launchArguments,
      in: root,
      log: log,
      append: true
    )
    guard status == 0 else { throw AppCtlError("simctl launch failed; log: \(log.path(percentEncoded: false))") }
  }

  func screenshot(on device: Device, to file: URL, log: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard Shell.run(["xcrun", "simctl", "io", device.udid, "screenshot", file.path], in: root, log: log) == 0 else {
      throw AppCtlError("screenshot failed; log: \(log.path(percentEncoded: false))")
    }
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
    let output = Shell.capture(["xcrun", "simctl", "list"] + arguments + ["-j"], in: root)
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

/// Talks to AgentBridge in the running app over loopback HTTP.
struct BridgeClient {
  let port: Int

  struct Response {
    var status: Int
    var body: String
    var exitCode: Int32
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
      exitCode: Int32(http?.value(forHTTPHeaderField: "X-Appctl-Exit") ?? "") ?? 3
    )
  }

  /// Polls `GET /snapshot` until the bridge answers, and returns the snapshot line.
  func waitUntilReady(timeout: Duration = .seconds(60)) async throws -> String {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let response = try? await send("GET", "/snapshot", timeout: 2), response.status == 200 {
        return response.body
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AppCtlError("AgentBridge did not answer on 127.0.0.1:\(port) within \(timeout)")
  }
}

struct AppCtlError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

enum Shell {
  static func which(_ tool: String) -> Bool {
    capture(["which", tool], in: URL(fileURLWithPath: "/")).contains("/")
  }

  /// Runs a command with its output in `log`; returns the exit status.
  @discardableResult
  static func run(_ arguments: [String], in directory: URL, log: URL, append: Bool = false) -> Int32 {
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !append || !FileManager.default.fileExists(atPath: log.path) {
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// Like ``run(_:in:log:append:)``, but watches the log. Once `isFinished(log)` is true, the process gets `grace`
  /// seconds to exit before it is terminated; it is always terminated after `timeout`. `xcodebuild test` sometimes
  /// hangs after the test run has finished. Returns the exit status, or nil if the process had to be terminated.
  static func runWatched(
    _ arguments: [String],
    in directory: URL,
    log: URL,
    grace: TimeInterval = 20,
    timeout: TimeInterval = 900,
    isFinished: (String) -> Bool
  ) -> Int32? {
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() } catch { return -1 }
    let start = Date()
    var finishedAt: Date?
    while process.isRunning {
      Thread.sleep(forTimeInterval: 0.5)
      if finishedAt == nil, let text = try? String(contentsOf: log, encoding: .utf8), isFinished(text) {
        finishedAt = Date()
      }
      let lingering = finishedAt.map { Date().timeIntervalSince($0) > grace } ?? false
      if lingering || Date().timeIntervalSince(start) > timeout {
        process.terminate()
        process.waitUntilExit()
        return nil
      }
    }
    return process.terminationStatus
  }

  /// Runs a command and returns its standard output.
  static func capture(_ arguments: [String], in directory: URL) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}
