// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import ComposableArchitecture

  /// How a ``ScriptRunner`` waits for the app and whether it can control time.
  @MainActor
  public struct RunnerEnvironment {
    public var settle: @MainActor () async -> SettleResult
    /// Moves the app's clock forward: the test clock headlessly, the ``AdvanceableClock`` in the running app. `nil`
    /// where the runtime controls no clock, and `advance` is then rejected.
    public var advance: (@MainActor (Duration) async -> Void)?
    /// Headless runs send each screen's `onAppear` action when it becomes active (no views exist to do it).
    public var synthesizesAppearance: Bool

    public init(
      settle: @escaping @MainActor () async -> SettleResult,
      advance: (@MainActor (Duration) async -> Void)?,
      synthesizesAppearance: Bool
    ) {
      self.settle = settle
      self.advance = advance
      self.synthesizesAppearance = synthesizesAppearance
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

    public let store: Store<Root.State, Root.Action>
    let callLog: MockCallLog
    let faults: MockFaults
    let tracker: EffectTracker
    let environment: RunnerEnvironment
    let pending: @MainActor () -> Int
    /// The methods `mock` accepts, supplied by the host that built this runner, since the app's clients — not
    /// this package — know which methods are mockable.
    let mockMethods: [MockMethod]
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
      mockMethods: [MockMethod]
    ) {
      self.store = store
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
      let screen = Root.activeScreen(state)
      guard let command = screen.command(named: line.name) else {
        let valid = (screen.commands.map(\.usage) + Self.runtimeCommandNames).joined(separator: ", ")
        return fail(line, status: .failed, "unknown command '\(line.name)' on \(screen.path). Valid here: \(valid)")
      }
      if let reason = command.disabledReason {
        return fail(line, status: .failed, "\(command.name) is disabled here (\(reason))")
      }
      let action: Root.Action
      do {
        action = try command.makeAction(line.argument.map(ArgumentText.unquoted))
      } catch {
        return fail(line, status: .failed, "\(command.usage): \(error.message)")
      }
      let start = callLog.count
      let before = state
      store.send(action)
      let settle = await settleAndAppear()
      return finish(command: line.text, callStart: start, settle: settle, before: before)
    }

    // MARK: - Helpers

    /// Settles; headlessly, also sends `onAppear` for each newly active screen until the screen is stable.
    private func settleAndAppear() async -> SettleResult {
      var result = await environment.settle()
      for _ in 0..<10 {
        let screen = Root.activeScreen(state)
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
      let screen = Root.activeScreen(state)
      return StepRecord(
        command: command,
        screen: screen.path,
        summary: screen.summary,
        calls: calls,
        error: screen.errorCode,
        pending: settle.pending,
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
