import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Testing

/// What this guards: the settling approach (``EffectTracker`` plus megaYield rounds) on toy reducers, so that it
/// is validated independently of any app's screens. `Toy` covers the effect shapes a real reducer produces:
/// immediate, chained, clock-suspended, a repeating timer, an actor hop, and cancellation.
@Reducer
struct Toy {
  @ObservableState
  struct State: Equatable {
    var value = 0
    var ticks = 0
  }

  enum Action: Sendable {
    case immediate
    case chain(Int)
    case sleep
    case startTimer
    case stopTimer
    case tick
    case setValue(Int)
    case backend
  }

  enum CancelID { case timer }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.mockCallLog) var callLog

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .immediate:
        return .run { send in await send(.setValue(1)) }
      case let .chain(remaining):
        state.value += 1
        return remaining > 1 ? .run { send in await send(.chain(remaining - 1)) } : .none
      case .sleep:
        return .run { send in
          try await clock.sleep(for: .seconds(30))
          await send(.setValue(30))
        }
      case .startTimer:
        return .run { send in
          for await _ in clock.timer(interval: .seconds(1)) {
            await send(.tick)
          }
        }
        .cancellable(id: CancelID.timer, cancelInFlight: true)
      case .stopTimer:
        return .cancel(id: CancelID.timer)
      case .tick:
        state.ticks += 1
        return state.ticks == 3 ? .cancel(id: CancelID.timer) : .none
      case let .setValue(value):
        state.value = value
        return .none
      case .backend:
        return .run { send in
          let value = await ToyBackend.shared.answer(log: callLog)
          await send(.setValue(value))
        }
      }
    }
  }
}

/// An actor hop inside an effect, like a mock backend's.
actor ToyBackend {
  static let shared = ToyBackend()
  func answer(log: MockCallLog) -> Int {
    log.begin("toy.answer")
    log.end("toy.answer")
    return 42
  }
}

@MainActor
struct ToyHarness {
  let store: StoreOf<Toy>
  let tracker = EffectTracker()
  let clock = TestClock()
  let countingClock: CountingClock<TestClock<Duration>>
  let callLog = MockCallLog()

  init() {
    let tracker = tracker
    let countingClock = CountingClock(clock)
    self.countingClock = countingClock
    let callLog = callLog
    store = Store(initialState: Toy.State()) {
      TrackingReducer(tracker: tracker, base: Toy())
    } withDependencies: {
      $0.continuousClock = countingClock
      $0.mockCallLog = callLog
    }
  }

  func send(_ action: Toy.Action) async -> SettleResult {
    store.send(action)
    return await settle()
  }

  func settle() async -> SettleResult {
    await settleHeadless(
      state: { store.state },
      callLog: callLog,
      tracker: tracker,
      pending: { [countingClock] in countingClock.activeSleeps }
    )
  }

  var state: Toy.State { store.state }
}

extension AgentCtlSuite {
  @MainActor
  @Suite struct SettleTests {
    @Test func immediateEffectIsAppliedWithinOneStep() async {
      await serially {
        let toy = ToyHarness()
        let result = await toy.send(.immediate)
        #expect(result == SettleResult(settled: true, pending: 0))
        #expect(toy.state.value == 1)
      }
    }

    @Test func chainedEffectsAllApply() async {
      await serially {
        let toy = ToyHarness()
        let result = await toy.send(.chain(3))
        #expect(result == SettleResult(settled: true, pending: 0))
        #expect(toy.state.value == 3)
      }
    }

    @Test func actorHopsInsideEffectsSettle() async {
      await serially {
        let toy = ToyHarness()
        let result = await toy.send(.backend)
        #expect(result.pending == 0)
        #expect(toy.state.value == 42)
        #expect(toy.callLog.entries == ["toy.answer"])
      }
    }

    @Test func clockSuspendedEffectIsPendingUntilAdvanced() async {
      await serially {
        let toy = ToyHarness()
        let first = await toy.send(.sleep)
        #expect(first == SettleResult(settled: true, pending: 1))
        #expect(toy.state.value == 0)
        await toy.clock.advance(by: .seconds(29))
        #expect(await toy.settle().pending == 1)
        await toy.clock.advance(by: .seconds(1))
        let second = await toy.settle()
        #expect(second == SettleResult(settled: true, pending: 0))
        #expect(toy.state.value == 30)
      }
    }

    @Test func timerTicksAndCancelsItself() async {
      await serially {
        let toy = ToyHarness()
        #expect(await toy.send(.startTimer).pending == 1)
        await toy.clock.advance(by: .seconds(2))
        #expect(await toy.settle().pending == 1)
        #expect(toy.state.ticks == 2)
        await toy.clock.advance(by: .seconds(5))
        #expect(await toy.settle().pending == 0)
        #expect(toy.state.ticks == 3)
      }
    }

    @Test func cancellationReleasesThePendingEffect() async {
      await serially {
        let toy = ToyHarness()
        #expect(await toy.send(.startTimer).pending == 1)
        #expect(await toy.send(.stopTimer).pending == 0)
        await toy.clock.advance(by: .seconds(10))
        #expect(toy.state.ticks == 0)
      }
    }

    @Test func settlingIsFast() async {
      await serially {
        let toy = ToyHarness()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 {
          _ = await toy.send(.chain(2))
        }
        #expect(start.duration(to: clock.now) < .milliseconds(500))
      }
    }
  }
}
