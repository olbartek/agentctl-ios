import AgentCtlCore
import ComposableArchitecture
import Foundation

/// The deterministic pieces `HeadlessHost` owns, handed to the host's `configure` closure so it can bind its own
/// backends to them.
///
/// The two clocks are one clock seen two ways:
/// - ``clock`` is the `TestClock` itself. Only `advance` moves it, so no time passes in a headless run unless a
///   script says so.
/// - ``countingClock`` is ``clock`` with the sleeps currently waiting on it counted. It is what the app sees as
///   `\.continuousClock`, and its count of active sleeps is the `pending` a step prints (CONTRACT.md §3.1): the
///   effects `advance` would release, such as a countdown.
///
/// A backend that only reads the time (a code's expiry, say) can be given either. One that sleeps should be given
/// ``countingClock``, so that its sleeps show up in `pending` like the app's own.
public struct HeadlessEnvironment {
  /// The virtual clock `advance` moves.
  public let clock: TestClock<Duration>
  /// ``clock``, with the sleeps waiting on it counted: the app's `\.continuousClock`, and the source of `pending`.
  public let countingClock: CountingClock<TestClock<Duration>>
  /// Every mock call, in order: what a step prints as `calls=`.
  public let callLog: MockCallLog
  /// The one-shot failures `mock` arms.
  public let faults: MockFaults
  /// Effects started and not yet finished. Settling waits for this count to stop changing, along with the state
  /// and the call log. It is not `pending`, which counts only sleeps on the clock.
  public let tracker: EffectTracker
}

/// A real store running on the Mac with the deterministic dependencies CONTRACT.md §6 requires.
///
/// It pins exactly these dependencies, then calls the host's `configure` closure:
///
/// | Dependency | Headless value |
/// |---|---|
/// | `\.continuousClock` | ``countingClock``: a `TestClock` that only `advance` moves |
/// | `\.uuid` | `.incrementing` |
/// | `\.date` | ``fixedDate``, 2026-01-01T09:00:00Z, for every call |
/// | `\.withRandomNumberGenerator` | a generator seeded with ``randomSeed`` |
/// | `\.timeZone` | ``fixedTimeZone``, UTC |
/// | `\.locale` | ``fixedLocale``, `en_US_POSIX` |
/// | `\.calendar` | ``fixedCalendar``, Gregorian in UTC |
/// | `\.mockLatency` | `.zero` |
/// | `\.mockCallLog`, `\.mockFaults` | fresh, per host |
///
/// Nothing else is pinned. In particular `\.mainQueue`, `\.suspendingClock` and any other source of time keep
/// their defaults, which are real (or, in a test process, unimplemented). A host whose app uses one must pin it in
/// `configure` — for a scheduler, with one it can advance deterministically. `configure` runs last, so what it
/// sets overrides everything in the table.
///
/// Run it with the main serial executor enabled (`Deterministic.isEnabled = true`).
@MainActor
public final class HeadlessHost<Root: Reducer & AgentContainer>
where
  Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  /// 2026-01-01T09:00:00Z: `\.date`.
  public static var fixedDate: Date { Date(timeIntervalSince1970: 1_767_258_000) }
  /// The seed of `\.withRandomNumberGenerator`: every headless run draws the same numbers in the same order.
  public static var randomSeed: UInt64 { 0 }
  /// UTC (which Foundation names `GMT`): `\.timeZone`, and the time zone of ``fixedCalendar``.
  public static var fixedTimeZone: TimeZone { TimeZone(identifier: "UTC") ?? .gmt }
  /// `en_US_POSIX`, the locale that does not follow user settings: `\.locale`.
  public static var fixedLocale: Locale { Locale(identifier: "en_US_POSIX") }
  /// The Gregorian calendar in ``fixedTimeZone``: `\.calendar`.
  public static var fixedCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = fixedTimeZone
    calendar.locale = fixedLocale
    return calendar
  }

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
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRandomNumberGenerator(seed: Self.randomSeed))
      $0.timeZone = Self.fixedTimeZone
      $0.locale = Self.fixedLocale
      $0.calendar = Self.fixedCalendar
      $0.mockLatency = .zero
      $0.mockCallLog = callLog
      $0.mockFaults = faults
      // Last, so the host can override any of the above, and pin what the list leaves out.
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

/// A random number generator whose sequence is fixed by its seed, on every run and every platform: SplitMix64.
struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
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
