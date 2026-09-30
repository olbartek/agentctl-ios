#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
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
      port: Int?
    ) async -> Int32 {
      guard let root = Repo.root() else { return RunStatus.internalError.rawValue }
      do {
        let requested = try BridgePort.requested(flag: port, environment: ProcessInfo.processInfo.environment)
        let result = try await launchApp(
          root: root, seed: seed, simulator: simulator, latency: latency, clearSession: clearSession, build: build,
          port: requested
        )
        print(result.report)
        return 0
      } catch {
        return fail(error)
      }
    }

    /// Builds (unless `build` is false) and launches the app, waits for its agent bridge, records where it listens
    /// in ``LaunchState``, and returns a one-line report.
    ///
    /// The bridge listens on `port` when one was requested (`--port`, `APPCTL_PORT`), else on the first free port
    /// of ``BridgePort/scanned``. The app is stopped first, so the port it held counts as free and a relaunch keeps it.
    ///
    /// The bridge that answers must say it is this app (`X-Appctl-App`): the app was built from the same checkout,
    /// so one that says nothing is another app. Then the app is relaunched once on the next free port, unless the
    /// port was requested.
    static func launchApp(
      root: URL,
      seed: String?,
      simulator: String,
      latency: Int?,
      clearSession: Bool,
      build: Bool,
      port requested: Int?
    ) async throws -> (device: Simulator.Device, port: Int, report: String) {
      let clock = ContinuousClock()
      let start = clock.now
      let sim = Simulator(root: root)
      let device = try sim.resolve(simulator)
      let log = Layout(root: root).logs.appending(path: "app-launch.log")
      sim.terminate(on: device, log: log)
      if build { try sim.buildAndInstall(on: device, log: log) }
      var options: [String] = []
      if let seed { options += ["-appctl-seed", seed] }
      if let latency { options += ["-mock-latency", String(latency)] }
      if clearSession { options.append("-clear-session") }
      func launch(on port: Int) async throws -> BridgeClient.Response {
        try sim.launch(on: device, launchArguments: ["-agent-port", String(port)] + options, log: log)
        return try await BridgeClient(port: port).waitUntilReady()
      }
      // Picked after the build, right before the launch: another app may have taken a port while it ran.
      var port = try BridgePort.launching(requested: requested)
      var answer = try await launch(on: port)
      if answer.app != Simulator.bundleID, requested == nil {
        sim.terminate(on: device, log: log)
        let taken = port
        port = try BridgePort.launching(requested: nil) { $0 > taken && BridgePort.isFree($0) }
        answer = try await launch(on: port)
      }
      guard answer.app == Simulator.bundleID else {
        sim.terminate(on: device, log: log)
        throw AppCtlError(Message.anotherApp(port: port, answeredAs: answer.app))
      }
      let snapshot = answer.body
      try LaunchState(device: device.udid, port: port, appId: Simulator.bundleID, launchedAt: Date()).write(in: root)
      let elapsed = start.duration(to: clock.now)
      let seconds = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
      let line = snapshot.split(separator: "\n").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      return (device, port, "launched on \(device.label) [\(device.udid)] at 127.0.0.1:\(port) in \(seconds)s: \(line)")
    }

    static func run(script: String, json: Bool, port flag: Int?) async -> Int32 {
      await send("POST", json ? "/run?format=json" : "/run", body: script, port: flag)
    }

    static func get(_ path: String, port flag: Int?) async -> Int32 {
      await send("GET", path, body: nil, port: flag)
    }

    /// Sends one request to the running app's bridge, prints the body and returns the bridge's exit code.
    private static func send(_ method: String, _ path: String, body: String?, port flag: Int?) async -> Int32 {
      let port: Int
      let source: BridgePort.Source
      do {
        (port, source) = try connection(flag: flag)
      } catch {
        return fail(error)
      }
      do {
        let client = BridgeClient(port: port)
        if case let .launchState(state) = source {
          // A script changes the app it runs in, so it is only posted once the recorded app is known to answer;
          // a GET changes nothing, and its own answer is checked instead.
          let answer = method == "GET" ? nil : try await client.send("GET", "/snapshot")
          if let app = answer?.app, app != state.appId {
            printError(Message.anotherApp(port: port, answeredAs: app, recorded: state.appId))
            return RunStatus.internalError.rawValue
          }
        }
        let response = try await client.send(method, path, body: body)
        if case let .launchState(state) = source, let app = response.app, app != state.appId {
          printError(Message.anotherApp(port: port, answeredAs: app, recorded: state.appId))
          return RunStatus.internalError.rawValue
        }
        print(response.body, terminator: response.body.hasSuffix("\n") ? "" : "\n")
        return response.exitCode
      } catch {
        printError(Message.bridgeUnreachable(port: port, source: source, error: error))
        return RunStatus.internalError.rawValue
      }
    }

    /// The running app's port: `--port`, `APPCTL_PORT`, the last launch's ``LaunchState``, or 8765. Outside a repo
    /// there is no launch state to read.
    static func connection(flag: Int?) throws -> (port: Int, source: BridgePort.Source) {
      try BridgePort.connecting(flag: flag, environment: ProcessInfo.processInfo.environment) {
        try Repo.find().flatMap { try LaunchState.read(in: $0) }
      }
    }

    /// Prints `error` and returns its exit code: 2 for a usage error, 3 for anything else.
    static func fail(_ error: any Error) -> Int32 {
      printError("\(error)")
      return error is UsageError ? RunStatus.usage.rawValue : RunStatus.internalError.rawValue
    }
  }
#endif
