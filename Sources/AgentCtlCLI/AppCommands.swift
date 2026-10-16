#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCore
  import AgentCtlRuntime
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
    ///
    /// Every launch makes a fresh token, passes it as `-agent-token` and records it beside the port; the caller gets it
    /// too, so a command that launches sends it without reading the file back (CONTRACT.md §8.6).
    static func launchApp(
      root: URL,
      seed: String?,
      simulator: String,
      latency: Int?,
      clearSession: Bool,
      build: Bool,
      port requested: Int?
    ) async throws -> (device: Simulator.Device, port: Int, token: String, report: String) {
      let clock = ContinuousClock()
      let start = clock.now
      let sim = Simulator(root: root)
      let log = Layout(root: root).logs.appending(path: "app-launch.log")
      let resolved = try sim.resolve(simulator)
      sim.terminate(on: resolved, log: log)
      let device = try sim.ready(resolved, boot: build, log: log)
      if build { try sim.buildAndInstall(on: device, log: log) }
      let token = BridgeToken.make()
      var options = [BridgeToken.argument, token]
      if let seed { options += ["-appctl-seed", seed] }
      if let latency { options += ["-mock-latency", String(latency)] }
      if clearSession { options.append("-clear-session") }
      /// The bridge's answer, or `nil` when none came and something else holds the port: the bridge could not listen.
      /// With no answer the app is stopped either way; the port is judged once it has let go of it.
      func launch(on port: Int) async throws -> BridgeClient.Response? {
        try sim.launch(on: device, launchArguments: ["-agent-port", String(port)] + options, log: log)
        do {
          return try await BridgeClient(port: port, token: token).waitUntilReady()
        } catch {
          sim.terminate(on: device, log: log)
          for _ in 0..<10 where !BridgePort.isFree(port) {
            try await Task.sleep(for: .milliseconds(100))
          }
          if BridgePort.isFree(port) { throw error }
          return nil
        }
      }
      func isOurs(_ answer: BridgeClient.Response?) -> Bool { answer?.identity.isOurs == true }
      // Picked after the build, right before the launch: another app may have taken a port while it ran.
      var port = try BridgePort.launching(requested: requested)
      var answer = try await launch(on: port)
      if !isOurs(answer), requested == nil {
        sim.terminate(on: device, log: log)
        let taken = port
        port = try BridgePort.launching(requested: nil) { $0 > taken && BridgePort.isFree($0) }
        answer = try await launch(on: port)
      }
      guard let answer, isOurs(answer) else {
        sim.terminate(on: device, log: log)
        throw AppCtlError(
          answer.map { Message.anotherApp(port: port, answeredAs: $0.identity) } ?? Message.portHeld(port: port)
        )
      }
      // Our own app, refusing our own token: nothing a relaunch on another port would change.
      if let refused = answer.refusal(port: port) {
        sim.terminate(on: device, log: log)
        throw refused
      }
      let snapshot = answer.body
      try LaunchState(device: device.udid, port: port, appId: Simulator.bundleID, launchedAt: Date(), token: token)
        .write(in: root)
      let elapsed = start.duration(to: clock.now)
      let seconds = String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
      let line = snapshot.split(separator: "\n").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      return (device, port, token, "launched on \(device.label) [\(device.udid)] at 127.0.0.1:\(port) in \(seconds)s: \(line)")
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
        let client = BridgeClient(port: port, token: token(port: port, source: source))
        if case let .launchState(state) = source {
          // A script changes the app it runs in, so it is only posted once the recorded app is known to answer;
          // a GET changes nothing, and its own answer is checked instead.
          let answer = method == "GET" ? nil : try await client.send("GET", "/snapshot")
          if let answer, answer.identity.contradicts(state) {
            printError(Message.anotherApp(port: port, answeredAs: answer.identity, recorded: state))
            return RunStatus.internalError.rawValue
          }
          if let refused = answer?.refusal(port: port) { throw refused }
        }
        let response = try await client.send(method, path, body: body)
        if case let .launchState(state) = source, response.identity.contradicts(state) {
          printError(Message.anotherApp(port: port, answeredAs: response.identity, recorded: state))
          return RunStatus.internalError.rawValue
        }
        // Who answered is checked first: a refusal from another app is that app's, not a wrong token.
        if let refused = response.refusal(port: port) { throw refused }
        print(response.body, terminator: response.body.hasSuffix("\n") ? "" : "\n")
        return response.exitCode
      } catch {
        printError(Message.bridgeUnreachable(port: port, source: source, error: error))
        return RunStatus.internalError.rawValue
      }
    }

    /// The token to send to the bridge on `port`: `APPCTL_TOKEN`, else the launch state's when it names that port. The
    /// file is read again only when the port did not come from it, and then a file that cannot be read has no token.
    static func token(port: Int, source: BridgePort.Source) -> String? {
      BridgeTokenSource.connecting(port: port, environment: ProcessInfo.processInfo.environment) {
        if case let .launchState(state) = source { return state }
        return try? Repo.find().flatMap { try LaunchState.read(in: $0) }
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
