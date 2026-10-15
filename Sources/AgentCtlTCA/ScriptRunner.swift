// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import ComposableArchitecture
  import Foundation

  /// How a ``ScriptRunner`` waits for the app and whether it can control time.
  @MainActor
  public struct RunnerEnvironment {
    public var settle: @MainActor () async -> SettleResult
    /// Moves the app's clock forward: the test clock headlessly, the ``AdvanceableClock`` in the running app. `nil`
    /// where the runtime controls no clock, and `advance` is then rejected.
    public var advance: (@MainActor (Duration) async -> Void)?
    /// Headless runs send each screen's `onAppear` action when it becomes active (no views exist to do it).
    public var synthesizesAppearance: Bool
    /// The store's dependencies. Screens, summaries and commands are computed inside them, so they read what the
    /// reducers read (the app's `\.date`, above all) rather than the ambient context. `nil` keeps the ambient one.
    public var dependencies: DependencyValues?

    public init(
      settle: @escaping @MainActor () async -> SettleResult,
      advance: (@MainActor (Duration) async -> Void)?,
      synthesizesAppearance: Bool,
      dependencies: DependencyValues? = nil
    ) {
      self.settle = settle
      self.advance = advance
      self.synthesizesAppearance = synthesizesAppearance
      self.dependencies = dependencies
    }
  }

  /// The exit codes of CONTRACT.md §5.
  public enum RunStatus: Int32, Sendable {
    case ok = 0
    /// A command or `expect` failed.
    case failed = 1
    /// A usage or parse error.
    case usage = 2
    case internalError = 3
  }

  public struct RunResult: Sendable {
    public var steps: [StepRecord]
    public var status: RunStatus
    /// The lines that ran successfully, for `--session` files.
    public var executed: [ScriptLine]
    /// The line that failed, if any.
    public var failedLine: ScriptLine?
    /// A failure that has no step, such as a script syntax error.
    public var message: String?
  }

  /// Runs script commands against a `Store<Root>`, headlessly (the CLI) or in the app (AgentCtlBridge).
  @MainActor
  public final class ScriptRunner<Root: Reducer & AgentContainer>
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    public static var runtimeCommandNames: [String] { ["expect", "advance", "mock"] }

    /// The store the script drives. `device relaunch` replaces it with a fresh one.
    public private(set) var store: Store<Root.State, Root.Action>
    let callLog: MockCallLog
    let faults: MockFaults
    let tracker: EffectTracker
    let environment: RunnerEnvironment
    let pending: @MainActor () -> Int
    /// The methods `mock` accepts, supplied by the host that built this runner, since the app's clients — not
    /// this package — know which methods are mockable.
    let mockMethods: [MockMethod]
    /// The simulated device `device` changes and the app's fakes read.
    public let device: AgentDevice
    let deviceConfig: AgentDeviceConfig<Root.Action>
    /// The `device` subcommands this app has.
    public let deviceSurface: DeviceSurface
    /// Builds a fresh store over the same dependencies, for `device relaunch`.
    let relaunch: (@MainActor () -> Store<Root.State, Root.Action>)?
    /// Adds a `customDump` diff of the root state to each step (`--diff`).
    public var recordsDiff = false
    private var lastIdentity: String?
    private var lastCalls: [String] = []
    /// How far `advance` has moved the clock so far.
    private var advanced: Duration = .zero

    /// The furthest `advance` moves the clock in one run, in total. A virtual clock's instant traps when it
    /// overflows, somewhere past 10^20 seconds; stopping at `Int.max` seconds keeps a script from crashing the
    /// process that way and leaves the app's own sleeps ample room beyond it.
    static var advanceLimit: Duration { .seconds(Int.max) }

    public init(
      store: Store<Root.State, Root.Action>,
      callLog: MockCallLog,
      faults: MockFaults,
      tracker: EffectTracker,
      pending: @escaping @MainActor () -> Int,
      environment: RunnerEnvironment,
      mockMethods: [MockMethod],
      device: AgentDevice = AgentDevice(),
      deviceConfig: AgentDeviceConfig<Root.Action> = .none,
      relaunch: (@MainActor () -> Store<Root.State, Root.Action>)? = nil
    ) {
      self.store = store
      self.device = device
      self.deviceConfig = deviceConfig
      self.deviceSurface = deviceConfig.surface
      self.relaunch = relaunch
      self.callLog = callLog
      self.faults = faults
      self.tracker = tracker
      self.pending = pending
      self.environment = environment
      self.mockMethods = mockMethods
    }

    public var state: Root.State { store.state }

    /// Settles the initial state (sending the first screen's appearance) and returns the `(launch)` step with its
    /// status.
    ///
    /// The status is `.failed` when the app did not settle — a `settled=false` step fails like any other
    /// (CONTRACT.md §3.1, §5). A caller must then not run a script: its first line would be evaluated against a
    /// starting state that is not known (§3.4).
    public func launch() async -> (step: StepRecord, status: RunStatus) {
      let start = callLog.count
      let before = state
      let settle = await settleAndAppear()
      return finish(command: "(launch)", callStart: start, settle: settle, before: before)
    }

    /// Parses and runs a script, stopping at the first failure.
    public func run(_ source: String) async -> RunResult {
      let lines: [ScriptLine]
      do {
        lines = try ScriptParser.parse(source)
      } catch {
        return RunResult(steps: [], status: .usage, executed: [], message: "parse error: \(error.description)")
      }
      return await run(lines)
    }

    public func run(_ lines: [ScriptLine]) async -> RunResult {
      var steps: [StepRecord] = []
      var executed: [ScriptLine] = []
      for line in lines {
        let (step, status) = await execute(line)
        steps.append(step)
        guard status == .ok else {
          return RunResult(steps: steps, status: status, executed: executed, failedLine: line)
        }
        executed.append(line)
      }
      return RunResult(steps: steps, status: .ok, executed: executed)
    }

    public func execute(_ line: ScriptLine) async -> (step: StepRecord, status: RunStatus) {
      switch line.name {
      case "expect":
        return expect(line)
      case "advance":
        return await advance(line)
      case "mock":
        return mock(line)
      case "device" where deviceSurface.exists:
        return await device(line)
      default:
        return await command(line)
      }
    }

    /// The current screen summary as a step, without running anything.
    public func snapshot(command: String) -> StepRecord {
      record(command: command, calls: lastCalls, settle: SettleResult(settled: true, pending: pending()))
    }

    // MARK: - Commands

    private func expect(_ line: ScriptLine) -> (step: StepRecord, status: RunStatus) {
      let expectation: Expectation
      do {
        expectation = try Expectation.parse(line.argument)
      } catch {
        return fail(line, status: .usage, error.message)
      }
      var step = snapshot(command: line.text)
      let failures = expectation.evaluate(step.snapshot)
      guard failures.isEmpty else {
        step.ok = false
        step.message = failures.joined(separator: "\n")
        return (step, .failed)
      }
      return (step, .ok)
    }

    private func advance(_ line: ScriptLine) async -> (step: StepRecord, status: RunStatus) {
      guard let argument = line.argument, let duration = ScriptParser.parseDuration(ArgumentText.unquoted(argument)) else {
        return fail(line, status: .usage, "advance needs a duration such as 500ms, 30s, 5m or 1h")
      }
      guard let advanceClock = environment.advance else {
        return fail(line, status: .usage, "advance is only available headlessly, not in the running app")
      }
      guard duration <= Self.advanceLimit - advanced else {
        return fail(line, status: .usage, "advance would take the clock past \(Int.max) seconds")
      }
      advanced += duration
      let start = callLog.count
      let before = state
      await advanceClock(duration)
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    private func mock(_ line: ScriptLine) -> (step: StepRecord, status: RunStatus) {
      let tokens = ArgumentText.tokens(line.argument ?? "")
      guard tokens.count == 2 else {
        let names = mockMethods.map(\.name).joined(separator: ", ")
        let mockable = names.isEmpty ? "" : "; mockable: \(names)"
        return fail(line, status: .usage, "usage: mock <client.method> <error> — exactly two words\(mockable)")
      }
      let (name, code) = (tokens[0], tokens[1])
      guard let method = mockMethods.first(where: { $0.name == name }) else {
        let names = mockMethods.map(\.name).joined(separator: ", ")
        return fail(line, status: .failed, "unknown mock method '\(name)'; mockable: \(names)")
      }
      guard method.errorCodes.contains(code) else {
        return fail(line, status: .failed, "unknown error '\(code)' for \(name); valid: \(method.errorCodes.joined(separator: ", "))")
      }
      faults.set(name, code: code)
      lastCalls = []
      return (snapshot(command: line.text), .ok)
    }

    private func command(_ line: ScriptLine) async -> (step: StepRecord, status: RunStatus) {
      let screen = activeScreen()
      guard let command = screen.command(named: line.name) else {
        let runtime = Self.runtimeCommandNames + (deviceSurface.exists ? ["device"] : [])
        let valid = (screen.commands.map(\.usage) + runtime).joined(separator: ", ")
        return fail(line, status: .failed, "unknown command '\(line.name)' on \(screen.path). Valid here: \(valid)")
      }
      if deviceSurface.subcommands.contains(.background), device.phase == .background {
        return fail(line, status: .failed, "\(command.name) is unavailable: the app is in the background (device foreground first)")
      }
      if let reason = command.disabledReason {
        return fail(line, status: .failed, "\(command.name) is disabled here (\(reason))")
      }
      let action: Root.Action
      do {
        action = try inAppContext { () throws(AgentCommandError) -> Root.Action in
          try command.makeAction(line.argument.map(ArgumentText.unquoted))
        }
      } catch {
        return fail(line, status: .failed, "\(command.usage): \(error.message)")
      }
      let start = callLog.count
      let before = state
      store.send(action)
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    // MARK: - device (CONTRACT.md §2.4)

    private func device(_ line: ScriptLine) async -> (step: StepRecord, status: RunStatus) {
      let surface = deviceSurface
      let available = surface.subcommands.map(\.rawValue).joined(separator: ", ")
      let tokens = ArgumentText.tokens(line.argument ?? "")
      guard let first = tokens.first else {
        return fail(line, status: .usage, "usage: device <subcommand>; available: \(available)")
      }
      guard let sub = DeviceSurface.Subcommand(rawValue: first) else {
        return fail(line, status: .usage, "unknown device command '\(first)'; available: \(available)")
      }
      guard surface.subcommands.contains(sub) else {
        return fail(line, status: .usage, "device \(first) is not configured by this app; available: \(available)")
      }
      let arguments = Array(tokens.dropFirst())
      func usage(_ text: String) -> (step: StepRecord, status: RunStatus) {
        fail(line, status: .usage, "usage: \(text)")
      }
      func failed(_ text: String) -> (step: StepRecord, status: RunStatus) {
        fail(line, status: .failed, text)
      }
      let services = surface.services.joined(separator: ", ")

      switch sub {
      case .permission:
        guard arguments.count == 2, let status = PermissionStatus(rawValue: arguments[1]) else {
          return usage("device permission <service> <not-determined|granted|denied|limited>; services: \(services)")
        }
        let service = arguments[0]
        guard surface.services.contains(service) else {
          return failed("unknown permission '\(service)'; services: \(services)")
        }
        guard !device.isPrompting(for: service) else {
          return failed(
            "device permission: a prompt for \(service) is pending; answer it with device prompt allow|deny|limited"
          )
        }
        return await settling(line) { device.setPermission(service, status) }

      case .prompt:
        let answers: [String: PermissionStatus] = ["allow": .granted, "deny": .denied, "limited": .limited]
        guard arguments.count == 1, let status = answers[arguments[0]] else {
          return usage("device prompt <allow|deny|limited>")
        }
        do {
          try device.answerPermission(status)
        } catch {
          switch error {
          case .noPrompt:
            return failed("device prompt: no prompt is pending")
          case let .otherPrompt(name):
            return failed("device prompt: the pending prompt is \(name); answer it with device biometry match|fail")
          }
        }
        return await settling(line) {}

      case .openURL:
        guard arguments.count == 1, let url = Self.parseURL(arguments[0]) else {
          return usage("device open-url <url>")
        }
        guard let action = inAppContext({ deviceConfig.openURL?(url) }) else {
          return failed("device open-url: the app does not handle \(arguments[0])")
        }
        return await settling(line) { store.send(action) }

      case .push:
        let names = surface.pushes.map(\.name).joined(separator: ", ")
        guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "tap") else {
          return usage("device push <name> [tap]; pushes: \(names)")
        }
        guard let push = deviceConfig.pushes.first(where: { $0.name == arguments[0] }) else {
          return failed("unknown push '\(arguments[0])'; pushes: \(names)")
        }
        let action = arguments.count == 2 ? push.opened : push.received
        return await settling(line) { if let action { store.send(action) } }

      case .background, .foreground:
        guard arguments.isEmpty else { return usage("device \(sub.rawValue)") }
        let phase: DevicePhase = sub == .background ? .background : .foreground
        let action = inAppContext { deviceConfig.scenePhase?(phase) }
        return await settling(line) {
          device.setPhase(phase)
          if let action { store.send(action) }
        }

      case .relaunch:
        guard arguments.isEmpty else { return usage("device relaunch") }
        guard let relaunch else { return failed("device relaunch is not available in this runtime") }
        return await settling(line) {
          // The old store goes with its effects (a root store cancels them as it is released); a prompt one of them
          // was waiting on goes with it, as when the app quits.
          store = relaunch()
          device.withdrawAllPrompts()
          device.setPhase(.foreground)
          lastIdentity = nil
        }

      case .network:
        guard arguments.count == 1, ["online", "offline"].contains(arguments[0]) else {
          return usage("device network <online|offline>")
        }
        return await settling(line) { device.setOnline(arguments[0] == "online") }

      case .location:
        guard arguments.count == 1, let location = DeviceLocation.parseArgument(arguments[0]) else {
          return usage("device location <lat>,<lon> or none, e.g. 52.2297,21.0122")
        }
        return await settling(line) { device.setLocation(location) }

      case .biometry:
        guard arguments.count == 1, ["enrolled", "unenrolled", "match", "fail"].contains(arguments[0]) else {
          return usage("device biometry <enrolled|unenrolled|match|fail>")
        }
        switch arguments[0] {
        case "enrolled", "unenrolled":
          return await settling(line) { device.setBiometryEnrolled(arguments[0] == "enrolled") }
        default:
          do {
            try device.answerBiometry(arguments[0] == "match" ? .success : .failure)
          } catch {
            return failed("device biometry: no biometric prompt is pending")
          }
          return await settling(line) {}
        }
      }
    }

    /// Runs `change`, then settles and prints the step, as a screen command does.
    private func settling(_ line: ScriptLine, _ change: () -> Void) async -> (step: StepRecord, status: RunStatus) {
      let start = callLog.count
      let before = state
      change()
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    /// An absolute URL: a scheme (`[A-Za-z][A-Za-z0-9+.-]*`), a colon, then no whitespace, parsed strictly (nothing
    /// percent-encoded on the way), so both ports accept and reject the same texts.
    static func parseURL(_ text: String) -> URL? {
      guard let colon = text.firstIndex(of: ":"), !text.contains(where: \.isWhitespace) else { return nil }
      let scheme = text[..<colon]
      guard let first = scheme.first, first.isASCII, first.isLetter,
        scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
      else { return nil }
      return URL(string: text, encodingInvalidCharacters: false)
    }

    // MARK: - Helpers

    /// The active screen, computed in the store's dependency context (see ``RunnerEnvironment/dependencies``).
    private func activeScreen() -> ActiveScreen<Root.Action> {
      inAppContext { Root.activeScreen(state) }
    }

    /// Runs `operation` in the store's dependency context, as reducers see it: a screen's summary, a command's
    /// disabled check and its argument parsing all read the app's `\.date`, not the ambient one.
    private func inAppContext<T, E: Error>(_ operation: () throws(E) -> T) throws(E) -> T {
      guard let dependencies = environment.dependencies else { return try operation() }
      // Through a Result, so the operation's typed error comes out typed.
      let result = withDependencies { $0 = dependencies } operation: { Result<T, E> { () throws(E) -> T in try operation() } }
      return try result.get()
    }

    /// Settles; headlessly, also sends `onAppear` for each newly active screen until the screen is stable.
    private func settleAndAppear() async -> SettleResult {
      var result = await environment.settle()
      for _ in 0..<10 {
        let screen = activeScreen()
        guard screen.identity != lastIdentity else { break }
        lastIdentity = screen.identity
        guard environment.synthesizesAppearance, let appear = screen.appearAction else { continue }
        store.send(appear)
        result = await environment.settle()
      }
      return result
    }

    private func finish(
      command: String,
      callStart: Int,
      settle: SettleResult,
      before: Root.State
    ) -> (step: StepRecord, status: RunStatus) {
      let calls = callLog.entries(since: callStart)
      lastCalls = calls
      var step = record(command: command, calls: calls, settle: settle)
      if recordsDiff {
        step.diff = diff(before, state)
      }
      guard settle.settled else {
        step.ok = false
        step.message = "did not settle within the time limit (a real-time dependency may have leaked in)"
        return (step, .failed)
      }
      return (step, .ok)
    }

    private func record(command: String, calls: [String], settle: SettleResult) -> StepRecord {
      let screen = activeScreen()
      return StepRecord(
        command: command,
        screen: screen.path,
        summary: screen.summary,
        calls: calls,
        error: screen.errorCode,
        pending: settle.pending,
        prompt: device.pendingPrompt,
        settled: settle.settled
      )
    }

    private func fail(_ line: ScriptLine, status: RunStatus, _ message: String) -> (step: StepRecord, status: RunStatus) {
      var step = record(command: line.text, calls: [], settle: SettleResult(settled: true, pending: pending()))
      step.ok = false
      step.message = message
      return (step, status)
    }
  }
#endif
