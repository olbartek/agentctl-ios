import AgentCtlCore
import ComposableArchitecture
import Foundation

/// The deterministic pieces `HeadlessHost` owns, handed to the app so it can bind its own backends to them.
public struct HeadlessEnvironment {
  public let clock: TestClock<Duration>
  public let countingClock: CountingClock<TestClock<Duration>>
  public let callLog: MockCallLog
  public let faults: MockFaults
  public let tracker: EffectTracker
}

/// A real store running on the Mac with the deterministic dependencies CONTRACT.md §6 requires: a `TestClock`,
/// incrementing
/// UUIDs, a fixed date, zero mock latency and fresh mock backends.
///
/// Run it with the main serial executor enabled (`Deterministic.isEnabled = true`).
@MainActor
public final class HeadlessHost<Root: Reducer & AgentContainer>
where
  Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  /// 2026-01-01T09:00:00Z.
  public static var fixedDate: Date { Date(timeIntervalSince1970: 1_767_258_000) }

  public let store: Store<Root.State, Root.Action>
  public let clock: TestClock<Duration>
  /// The clock the app sees: `clock`, with its active sleeps counted for `pending`.
  public let countingClock: CountingClock<TestClock<Duration>>
  public let callLog: MockCallLog
  public let faults: MockFaults
  public let tracker: EffectTracker
  let mockMethods: [MockMethod]

  public init(
    initialState: @escaping () -> Root.State,
    reducer: @escaping () -> Root,
    mockMethods: [MockMethod],
    configure: @escaping (inout DependencyValues, HeadlessEnvironment) -> Void
  ) {
    let clock = TestClock()
    let countingClock = CountingClock(clock)
    let callLog = MockCallLog()
    let faults = MockFaults()
    let tracker = EffectTracker()
    self.clock = clock
    self.countingClock = countingClock
    self.callLog = callLog
    self.faults = faults
    self.tracker = tracker
    self.mockMethods = mockMethods
    let environment = HeadlessEnvironment(
      clock: clock, countingClock: countingClock, callLog: callLog, faults: faults, tracker: tracker
    )
    // `initialState()` must be called here, inside `Store.init`'s `@autoclosure` argument, not before: that
    // autoclosure is what `Store.init` evaluates inside `withDependencies`, so root state built from a
    // `@Dependency` or declaring `@Shared` sees the deterministic overrides below instead of live defaults.
    self.store = Store(initialState: initialState()) {
      TrackingReducer(tracker: tracker, base: reducer())
    } withDependencies: {
      $0.continuousClock = countingClock
      $0.uuid = .incrementing
      $0.date = .constant(Self.fixedDate)
      $0.mockLatency = .zero
      $0.mockCallLog = callLog
      $0.mockFaults = faults
      configure(&$0, environment)
    }
  }

  public func settle() async -> SettleResult {
    await settleHeadless(
      state: { store.state }, callLog: callLog, tracker: tracker,
      pending: { [countingClock] in countingClock.activeSleeps }
    )
  }

  public func makeRunner() -> ScriptRunner<Root> {
    ScriptRunner(
      store: store, callLog: callLog, faults: faults, tracker: tracker,
      pending: { [countingClock] in countingClock.activeSleeps },
      environment: RunnerEnvironment(
        settle: { [self] in await settle() },
        advance: { [clock] duration in await clock.advance(by: duration) },
        synthesizesAppearance: true
      ),
      mockMethods: mockMethods
    )
  }
}

/// The pieces `LiveHost` owns, handed to the app so it can bind its own backends to them.
public struct LiveEnvironment {
  public let clock: CountingClock<ContinuousClock>
  public let callLog: MockCallLog
  public let faults: MockFaults
  public let tracker: EffectTracker
  public let latency: MockLatency
}

/// The app's store as AgentCtlBridge runs it in DEBUG builds: real time and real mock latency, plus the hooks the
/// agent runtime needs (call log, faults, effect tracking and a clock that counts pending sleeps).
@MainActor
public final class LiveHost<Root: Reducer & AgentContainer>
where
  Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  public let store: Store<Root.State, Root.Action>
  public let callLog: MockCallLog
  public let faults: MockFaults
  public let tracker: EffectTracker
  public let clock: CountingClock<ContinuousClock>
  let mockMethods: [MockMethod]

  public init(
    initialState: @escaping () -> Root.State,
    reducer: @escaping () -> Root,
    latency: MockLatency,
    mockMethods: [MockMethod],
    configure: @escaping (inout DependencyValues, LiveEnvironment) -> Void
  ) {
    let callLog = MockCallLog()
    let faults = MockFaults()
    let tracker = EffectTracker()
    let clock = CountingClock(ContinuousClock())
    self.callLog = callLog
    self.faults = faults
    self.tracker = tracker
    self.clock = clock
    self.mockMethods = mockMethods
    let environment = LiveEnvironment(clock: clock, callLog: callLog, faults: faults, tracker: tracker, latency: latency)
    // See the note in `HeadlessHost.init`: `initialState()` runs inside `Store.init`'s autoclosure, so it
    // sees these overrides too.
    self.store = Store(initialState: initialState()) {
      TrackingReducer(tracker: tracker, base: reducer())
    } withDependencies: {
      // Explicit, so the store behaves the same in a test process (where defaults are unimplemented).
      $0.continuousClock = clock
      $0.uuid = UUIDGenerator { UUID() }
      $0.date = DateGenerator { Date() }
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
      $0.mockLatency = latency
      $0.mockCallLog = callLog
      $0.mockFaults = faults
      configure(&$0, environment)
    }
  }

  /// Settles on real time — no mock call in flight, and the state quiet for a moment — because a running app's
  /// latency and timers are real, unlike the headless host's.
  public func settle() async -> SettleResult {
    await settleLive(
      state: { store.state },
      callLog: callLog,
      pending: { [clock] in clock.activeSleeps },
      quietWindow: .milliseconds(250)
    )
  }

  /// - Parameter synthesizesAppearance: `true` for launch seeding (before any view exists), `false` once the
  ///   views are on screen and send their own `onAppear`.
  public func makeRunner(synthesizesAppearance: Bool) -> ScriptRunner<Root> {
    ScriptRunner(
      store: store,
      callLog: callLog,
      faults: faults,
      tracker: tracker,
      pending: { [clock] in clock.activeSleeps },
      environment: RunnerEnvironment(
        settle: { [self] in await settle() },
        advance: nil,
        synthesizesAppearance: synthesizesAppearance
      ),
      mockMethods: mockMethods
    )
  }
}
