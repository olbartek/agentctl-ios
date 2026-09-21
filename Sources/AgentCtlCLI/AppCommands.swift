#if os(macOS)
  import AgentCtlTCA
  import Foundation

  /// `appctl app …` implementations.
  enum AppCommands {
    static func launch(
      seed: String?,
      simulator: String,
      latency: Int?,
      clearSession: Bool,
      build: Bool,
      port: Int
    ) async -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      do {
        let result = try await launchApp(
          root: root, seed: seed, simulator: simulator, latency: latency, clearSession: clearSession, build: build,
          port: port
        )
        print(result.report)
        return 0
      } catch {
        printError("\(error)")
        return RunStatus.internalError.rawValue
      }
    }

    /// Builds (unless `build` is false) and launches the app, waits for its agent bridge, and returns a one-line
    /// report.
    static func launchApp(
      root: URL,
      seed: String?,
      simulator: String,
      latency: Int?,
      clearSession: Bool,
      build: Bool,
      port: Int
    ) async throws -> (device: Simulator.Device, report: String) {
      let clock = ContinuousClock()
      let start = clock.now
      let sim = Simulator(root: root)
      let device = try sim.resolve(simulator)
      var arguments = ["-agent-port", String(port)]
      if let seed { arguments += ["-appctl-seed", seed] }
      if let latency { arguments += ["-mock-latency", String(latency)] }
      if clearSession { arguments.append("-clear-session") }
      let log = root.appending(path: ".appctl/logs/app-launch.log")
      if build {
        try sim.buildAndRun(on: device, launchArguments: arguments, log: log)
      } else {
        try sim.launch(on: device, launchArguments: arguments, log: log)
      }
      let snapshot = try await BridgeClient(port: port).waitUntilReady()
      let elapsed = start.duration(to: clock.now)
      let seconds = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
      let line = snapshot.split(separator: "\n").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      return (device, "launched on \(device.label) [\(device.udid)] in \(seconds)s: \(line)")
    }

    static func run(script: String, json: Bool, port: Int) async -> Int32 {
      do {
        let response = try await BridgeClient(port: port).send("POST", json ? "/run?format=json" : "/run", body: script)
        print(response.body, terminator: response.body.hasSuffix("\n") ? "" : "\n")
        return response.exitCode
      } catch {
        printError(Message.bridgeUnreachable(port: port, error: error))
        return RunStatus.internalError.rawValue
      }
    }

    static func get(_ path: String, port: Int) async -> Int32 {
      do {
        let response = try await BridgeClient(port: port).send("GET", path)
        print(response.body, terminator: response.body.hasSuffix("\n") ? "" : "\n")
        return response.exitCode
      } catch {
        printError(Message.bridgeUnreachable(port: port, error: error))
        return RunStatus.internalError.rawValue
      }
    }
  }
#endif
