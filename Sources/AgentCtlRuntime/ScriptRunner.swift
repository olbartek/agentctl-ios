// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import Dependencies
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
    /// The app's dependencies. Screens, summaries and commands are computed inside them, so they read what the
    /// reducers read (the app's `\.date`, above all) rather than the ambient context. `nil` keeps the ambient one.
    public var dependencies: DependencyValues?
    /// Headlessly, how long until the earliest sleep on the virtual clock ends (`nil` when nothing sleeps): `wait`
    /// moves the clock from one deadline to the next. `nil` in the running app, where `wait` waits in real time.
    public var timeUntilNextSleep: (@MainActor () -> Duration?)?

    public init(
      settle: @escaping @MainActor () async -> SettleResult,
      advance: (@MainActor (Duration) async -> Void)?,
      synthesizesAppearance: Bool,
      dependencies: DependencyValues? = nil,
      timeUntilNextSleep: (@MainActor () -> Duration?)? = nil
    ) {
      self.settle = settle
      self.advance = advance
      self.synthesizesAppearance = synthesizesAppearance
      self.dependencies = dependencies
      self.timeUntilNextSleep = timeUntilNextSleep
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

    /// What a headless caller makes of a run that threw `CancellationError`, which nothing headless does: exit 3.
    package static var cancelled: RunResult {
      RunResult(steps: [], status: .internalError, executed: [], message: "cancelled")
    }
  }

  /// Runs script commands against an app through its ``AgentDriver``, headlessly (the CLI) or in the app
  /// (AgentCtlBridge).
  @MainActor
  public final class ScriptRunner<Driver: AgentDriver> {
    public static var runtimeCommandNames: [String] { ["expect", "advance", "mock", "wait"] }

    /// The app the script drives. `device relaunch` has it replace the app with a fresh one.
    public let driver: Driver
    let callLog: MockCallLog
    let faults: MockFaults
    let environment: RunnerEnvironment
    let pending: @MainActor () -> Int
    /// The methods `mock` accepts, supplied by the host that built this runner, since the app's clients — not
    /// this package — know which methods are mockable.
    let mockMethods: [MockMethod]
    /// The simulated device `device` changes and the app's fakes read.
    public let device: AgentDevice
    let deviceConfig: AgentDeviceConfig<Driver.Action>
    /// The `device` subcommands this app has.
    public let deviceSurface: AgentDevice.Surface
    /// Adds a diff of the app's state to each step (`--diff`).
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
      driver: Driver,
      callLog: MockCallLog,
      faults: MockFaults,
      pending: @escaping @MainActor () -> Int,
      environment: RunnerEnvironment,
      mockMethods: [MockMethod],
      device: AgentDevice = AgentDevice(),
      deviceConfig: AgentDeviceConfig<Driver.Action> = .none
    ) {
      self.driver = driver
      self.device = device
      self.deviceConfig = deviceConfig
      self.deviceSurface = deviceConfig.surface
      self.callLog = callLog
      self.faults = faults
      self.pending = pending
      self.environment = environment
      self.mockMethods = mockMethods
    }

    /// The whole state, as `state` and `GET /state` print it.
    public var stateDump: String { driver.stateDump }

    /// Settles the initial state (sending the first screen's appearance) and returns the `(launch)` step with its
    /// status.
    ///
    /// The status is `.failed` when the app did not settle — a `settled=false` step fails like any other
    /// (CONTRACT.md §3.1, §5). A caller must then not run a script: its first line would be evaluated against a
    /// starting state that is not known (§3.4).
    public func launch() async -> (step: StepRecord, status: RunStatus) {
      let start = callLog.count
      let before = driver.stateSnapshot()
      let settle = await settleAndAppear()
      return finish(command: "(launch)", callStart: start, settle: settle, before: before)
    }

    /// Parses and runs a script, stopping at the first failure.
    ///
    /// Throws `CancellationError` when the task running it is cancelled — in the running app, when the bridge client
    /// that sent it has gone away (CONTRACT.md §8.1) — and then runs no further line. Nothing cancels a headless run.
    public func run(_ source: String) async throws(CancellationError) -> RunResult {
      let lines: [ScriptLine]
      do {
        lines = try ScriptParser.parse(source)
      } catch {
        return RunResult(steps: [], status: .usage, executed: [], message: "parse error: \(error.description)")
      }
      return try await run(lines)
    }

    /// Runs parsed lines, stopping at the first failure. Throws `CancellationError` as ``run(_:)-(String)`` does.
    public func run(_ lines: [ScriptLine]) async throws(CancellationError) -> RunResult {
      var steps: [StepRecord] = []
      var executed: [ScriptLine] = []
      for line in lines {
        // Cancelled (the bridge client that sent it went away, CONTRACT.md §8.1): run nothing more.
        if Task.isCancelled { throw CancellationError() }
        let (step, status) = await execute(line)
        // Cancelled during the line, whose settling it cut short: its step is not one to report.
        if Task.isCancelled { throw CancellationError() }
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
      case "wait":
        return await wait(line)
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
      let before = driver.stateSnapshot()
      await advanceClock(duration)
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    // MARK: - wait (CONTRACT.md §2.5)

    /// How often a `wait` in the running app looks at the screen.
    static var waitPollInterval: Duration { .milliseconds(20) }

    /// Waits until the screen matches the line's pairs, or, with none, until its line changes; fails once the
    /// duration has passed. Headlessly the virtual clock moves from one sleep's deadline to the next, settling after
    /// each, and stops at the one that brings the match; in the running app real time passes, and what the screen
    /// shows counts once the app has settled on it.
    private func wait(_ line: ScriptLine) async -> (step: StepRecord, status: RunStatus) {
      let arguments: WaitArguments
      do {
        arguments = try WaitArguments.parse(line.argument)
      } catch {
        return fail(line, status: .usage, error.message)
      }
      let duration = arguments.duration
      let start = callLog.count
      let before = driver.stateSnapshot()
      let initial = snapshot(command: line.text)
      /// The step as it stands, with the calls made since the wait began, and what still keeps it from matching.
      func current(_ settle: SettleResult) -> (step: StepRecord, unmet: [String]) {
        let step = record(command: line.text, calls: callLog.entries(since: start), settle: settle)
        guard let expectation = arguments.expectation else {
          let changed =
            step.screen != initial.screen || step.summary != initial.summary || step.error != initial.error
            || step.prompt != initial.prompt
          return (step, changed ? [] : ["nothing changed"])
        }
        return (step, expectation.evaluate(step.snapshot))
      }

      var settle = SettleResult(settled: true, pending: pending())
      if let timeUntilNextSleep = environment.timeUntilNextSleep, let advanceClock = environment.advance {
        guard duration <= Self.advanceLimit - advanced else {
          return fail(line, status: .usage, "wait would take the clock past \(Int.max) seconds")
        }
        var waited = Duration.zero
        // A bound, in case a sleep keeps its deadline where it is without ever finishing.
        for _ in 0..<10_000 where waited < duration && !current(settle).unmet.isEmpty {
          let step = min(max(timeUntilNextSleep() ?? duration, .zero), duration - waited)
          await advanceClock(step)
          advanced += step
          waited += step
          settle = await settleAndAppear()
          guard settle.settled else { break }
        }
      } else {
        // The start is the state the previous step settled on. A change or match counts once the app has settled
        // on it, so a transition's passing frames are never reported, and a state the app only passes through is
        // waited past.
        let clock = ContinuousClock()
        let began = clock.now
        while !Task.isCancelled {
          if !current(settle).unmet.isEmpty {
            let left = duration - began.duration(to: clock.now)
            guard left > .zero else { break }
            try? await clock.sleep(for: min(Self.waitPollInterval, left))
            continue
          }
          settle = await settleAndAppear()
          guard settle.settled, !current(settle).unmet.isEmpty else { break }
        }
      }

      var (step, status) = finish(command: line.text, callStart: start, settle: settle, before: before)
      guard status == .ok else { return (step, status) }
      let unmet = current(settle).unmet
      guard unmet.isEmpty else {
        step.ok = false
        step.message = (["wait timed out after \(ScriptParser.formatDuration(duration))"] + unmet).joined(separator: "\n")
        return (step, .failed)
      }
      return (step, status)
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
      let action: Driver.Action
      do {
        action = try inAppContext { () throws(AgentCommandError) -> Driver.Action in
          try command.makeAction(line.argument.map(ArgumentText.unquoted))
        }
      } catch {
        return fail(line, status: .failed, "\(command.usage): \(error.message)")
      }
      let start = callLog.count
      let before = driver.stateSnapshot()
      driver.send(action)
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
      guard let sub = AgentDevice.Surface.Subcommand(rawValue: first) else {
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
        guard arguments.count == 2, let status = AgentDevice.PermissionStatus(rawValue: arguments[1]) else {
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
        let answers: [String: AgentDevice.PermissionStatus] = ["allow": .granted, "deny": .denied, "limited": .limited]
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
        return await settling(line) { driver.send(action) }

      case .push:
        let names = surface.pushes.map(\.name).joined(separator: ", ")
        guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "tap") else {
          return usage("device push <name> [tap]; pushes: \(names)")
        }
        guard let push = deviceConfig.pushes.first(where: { $0.name == arguments[0] }) else {
          return failed("unknown push '\(arguments[0])'; pushes: \(names)")
        }
        let action = arguments.count == 2 ? push.opened : push.received
        return await settling(line) { if let action { driver.send(action) } }

      case .background, .foreground:
        guard arguments.isEmpty else { return usage("device \(sub.rawValue)") }
        let phase: AgentDevice.Phase = sub == .background ? .background : .foreground
        let action = inAppContext { deviceConfig.scenePhase?(phase) }
        return await settling(line) {
          device.setPhase(phase)
          if let action { driver.send(action) }
        }

      case .relaunch:
        guard arguments.isEmpty else { return usage("device relaunch") }
        return await settling(line) {
          // The old app goes with its work (the driver cancels it); a prompt that work was waiting on goes with it,
          // as when the app quits.
          driver.relaunch()
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
        guard arguments.count == 1, let location = AgentDevice.Location.parseArgument(arguments[0]) else {
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
      let before = driver.stateSnapshot()
      change()
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    /// An absolute URL: a scheme (`[A-Za-z][A-Za-z0-9+.-]*`), a colon, at least one character after it, and no
    /// whitespace, parsed strictly (nothing percent-encoded on the way), so both ports accept and reject the same texts.
    static func parseURL(_ text: String) -> URL? {
      guard let colon = text.firstIndex(of: ":"), text.index(after: colon) != text.endIndex,
        !text.contains(where: \.isWhitespace)
      else { return nil }
      let scheme = text[..<colon]
      guard let first = scheme.first, first.isASCII, first.isLetter,
        scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
      else { return nil }
      if #available(iOS 17, *) {
        return URL(string: text, encodingInvalidCharacters: false)
      }
      // Before iOS 17, `URL(string:)` was already strict: it never percent-encoded.
      return URL(string: text)
    }

    // MARK: - Helpers

    /// The active screen, computed in the app's dependency context (see ``RunnerEnvironment/dependencies``).
    private func activeScreen() -> ActiveScreen<Driver.Action> {
      inAppContext { driver.activeScreen() }
    }

    /// Runs `operation` in the app's dependency context, as the app sees it: a screen's summary, a command's
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
        driver.send(appear)
        result = await environment.settle()
      }
      return result
    }

    private func finish(
      command: String,
      callStart: Int,
      settle: SettleResult,
      before: Driver.StateSnapshot
    ) -> (step: StepRecord, status: RunStatus) {
      let calls = callLog.entries(since: callStart)
      lastCalls = calls
      var step = record(command: command, calls: calls, settle: settle)
      if recordsDiff {
        step.diff = driver.stateDiff(from: before)
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
