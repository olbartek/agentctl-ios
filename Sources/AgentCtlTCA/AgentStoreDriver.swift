// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  @_exported import AgentCtlRuntime
  import ComposableArchitecture

  /// The ``AgentDriver`` of an app built with the Composable Architecture: a `Store` of its root reducer, which is an
  /// ``AgentContainer``.
  ///
  /// Settling compares the root state and the effects in flight (an ``EffectTracker`` wraps the reducer); `state`
  /// and `--diff` are `customDump`s of the root state; a relaunch builds a fresh store from the initial state over the
  /// same dependencies, and the old store's effects are cancelled as it is released.
  @MainActor
  public final class AgentStoreDriver<Root: Reducer & AgentContainer>: AgentDriver
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    public typealias Action = Root.Action
    public typealias RootState = Root.State

    public struct Fingerprint: Equatable {
      var state: Root.State
      var effects: Int
    }

    /// The store the app shows. A relaunch replaces it.
    public private(set) var store: Store<Root.State, Root.Action>
    /// Effects started and not yet finished: what settling waits on besides the state.
    public let tracker: EffectTracker
    let dependencies: DependencyValues
    let initialState: () -> Root.State
    let reducer: () -> Root
    public var onRelaunch: (@MainActor () -> Void)?

    public init(dependencies: DependencyValues, initialState: @escaping () -> Root.State, reducer: @escaping () -> Root) {
      let tracker = EffectTracker()
      self.tracker = tracker
      self.dependencies = dependencies
      self.initialState = initialState
      self.reducer = reducer
      // `initialState()` must be called here, inside `Store.init`'s `@autoclosure` argument, not before: that
      // autoclosure is what `Store.init` evaluates inside `withDependencies`, so root state built from a
      // `@Dependency` or declaring `@Shared` sees the host's dependencies instead of live defaults.
      store = Store(initialState: initialState()) {
        TrackingReducer(tracker: tracker, base: reducer())
      } withDependencies: {
        $0 = dependencies
      }
    }

    public var app: Store<Root.State, Root.Action> { store }

    public var state: Root.State { store.state }

    public func activeScreen() -> ActiveScreen<Root.Action> {
      Root.activeScreen(store.state)
    }

    public func send(_ action: Root.Action) {
      store.send(action)
    }

    public func fingerprint() -> Fingerprint {
      Fingerprint(state: store.state, effects: tracker.inFlight)
    }

    public func relaunch() {
      store = Store(initialState: initialState()) { [tracker, reducer] in
        TrackingReducer(tracker: tracker, base: reducer())
      } withDependencies: { [dependencies] in
        $0 = dependencies
      }
      onRelaunch?()
    }

    public func stateSnapshot() -> Root.State {
      store.state
    }

    public func stateDiff(from before: Root.State) -> String? {
      diff(before, store.state)
    }

    public var stateDump: String {
      var output = ""
      customDump(store.state, to: &output)
      return output
    }
  }

  extension HeadlessHost {
    /// A TCA app, headlessly: a store of `reducer` from `initialState`, built inside the host's dependencies.
    public convenience init<Root: Reducer & AgentContainer>(
      initialState: @escaping () -> Root.State,
      reducer: @escaping () -> Root,
      mockMethods: [MockMethod],
      device deviceConfig: AgentDeviceConfig<Root.Action> = .none,
      configure: @escaping (inout DependencyValues, HeadlessEnvironment) -> Void
    )
    where
      Driver == AgentStoreDriver<Root>,
      Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
      Root.AgentState == Root.State, Root.AgentAction == Root.Action
    {
      self.init(mockMethods: mockMethods, device: deviceConfig, configure: configure) { dependencies in
        AgentStoreDriver(dependencies: dependencies, initialState: initialState, reducer: reducer)
      }
    }
  }

  extension LiveHost {
    /// A TCA app in the running app (AgentCtlBridge): real time and real mock latency.
    public convenience init<Root: Reducer & AgentContainer>(
      initialState: @escaping () -> Root.State,
      reducer: @escaping () -> Root,
      latency: MockLatency,
      mockMethods: [MockMethod],
      device deviceConfig: AgentDeviceConfig<Root.Action> = .none,
      configure: @escaping (inout DependencyValues, LiveEnvironment) -> Void
    )
    where
      Driver == AgentStoreDriver<Root>,
      Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
      Root.AgentState == Root.State, Root.AgentAction == Root.Action
    {
      self.init(latency: latency, mockMethods: mockMethods, device: deviceConfig, configure: configure) { dependencies in
        AgentStoreDriver(dependencies: dependencies, initialState: initialState, reducer: reducer)
      }
    }
  }

  extension HeadlessHost where Driver: AgentStoreDriving {
    /// The app's store.
    public var store: Driver.App { driver.app }
  }

  extension LiveHost where Driver: AgentStoreDriving {
    /// The app's store.
    public var store: Driver.App { driver.app }
  }

  extension ScriptRunner where Driver: AgentStoreDriving {
    /// The store the script drives.
    public var store: Driver.App { driver.app }
    /// The root state.
    public var state: Driver.RootState { driver.state }
  }

  /// ``AgentStoreDriver``, for extensions that need to know an app is a TCA store without naming its root.
  @MainActor
  public protocol AgentStoreDriving: AgentDriver {
    associatedtype RootState
    var state: RootState { get }
  }

  extension AgentStoreDriver: AgentStoreDriving {}
#endif
