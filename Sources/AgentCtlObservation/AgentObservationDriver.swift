// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  @_exported import AgentCtlRuntime
  import CustomDump
  import Dependencies

  /// The ``AgentDriver`` of an MVVM-C app: an ``AgentCoordinator`` and its `@Observable` view models.
  ///
  /// - Only the coordinator is built inside the host's dependencies. ``send(_:)`` runs an intent in the ambient
  ///   context, as a tap does in the running app, so an app has to carry its dependencies itself: child view models
  ///   created with `withDependencies(from:)`, tasks started through ``AgentTasks``. An app that forgets fails
  ///   headlessly, where it is cheap to see, rather than only in the running app.
  /// - There is no root state to compare. The fingerprint is the active screen as an agent sees it (identity, path,
  ///   summary, error) plus the tasks in flight: a change no summary shows cannot be what a later round waits on,
  ///   since any waiting is a task, and tasks are counted.
  @MainActor
  public final class AgentObservationDriver<Coordinator: AgentCoordinator>: AgentDriver {
    public typealias Action = AgentIntent<Coordinator>

    public struct Fingerprint: Equatable {
      var identity: String
      var path: String
      var summary: [SummaryItem]
      var error: String?
      var tasks: Int
    }

    /// The coordinator the app shows. A relaunch replaces it.
    public private(set) var app: Coordinator
    let dependencies: DependencyValues
    let make: @MainActor () -> Coordinator
    public var onRelaunch: (@MainActor () -> Void)?

    /// - Parameter make: builds the coordinator, in `dependencies`; called again on every relaunch.
    public init(dependencies: DependencyValues, coordinator make: @escaping @MainActor () -> Coordinator) {
      self.dependencies = dependencies
      self.make = make
      self.app = withDependencies { $0 = dependencies } operation: { make() }
    }

    public func activeScreen() -> ActiveScreen<AgentIntent<Coordinator>> {
      app.activeScreen()
    }

    public func send(_ action: AgentIntent<Coordinator>) {
      action.run(app)
    }

    public func fingerprint() -> Fingerprint {
      let screen = withDependencies { $0 = dependencies } operation: { app.activeScreen() }
      return Fingerprint(
        identity: screen.identity, path: screen.path, summary: screen.summary, error: screen.errorCode,
        tasks: dependencies.agentTasks.inFlight
      )
    }

    public func relaunch() {
      app.cancelAllWork()
      app = withDependencies { $0 = dependencies } operation: { make() }
      onRelaunch?()
    }

    public func stateSnapshot() -> String {
      stateDump
    }

    public func stateDiff(from before: String) -> String? {
      diff(before, stateDump)
    }

    public var stateDump: String {
      app.agentStateDump
    }
  }

  extension HeadlessHost {
    /// An MVVM-C app, headlessly: `coordinator` builds the app's coordinator inside the host's dependencies.
    public convenience init<Coordinator: AgentCoordinator>(
      mockMethods: [MockMethod],
      device deviceConfig: AgentDeviceConfig<AgentIntent<Coordinator>> = .none,
      configure: @escaping (inout DependencyValues, HeadlessEnvironment) -> Void,
      coordinator: @escaping @MainActor () -> Coordinator
    ) where Driver == AgentObservationDriver<Coordinator> {
      self.init(mockMethods: mockMethods, device: deviceConfig, configure: configure) { dependencies in
        AgentObservationDriver(dependencies: dependencies, coordinator: coordinator)
      }
    }
  }

  extension LiveHost {
    /// An MVVM-C app in the running app (AgentCtlBridge): real time and real mock latency.
    public convenience init<Coordinator: AgentCoordinator>(
      latency: MockLatency,
      mockMethods: [MockMethod],
      device deviceConfig: AgentDeviceConfig<AgentIntent<Coordinator>> = .none,
      configure: @escaping (inout DependencyValues, LiveEnvironment) -> Void,
      coordinator: @escaping @MainActor () -> Coordinator
    ) where Driver == AgentObservationDriver<Coordinator> {
      self.init(latency: latency, mockMethods: mockMethods, device: deviceConfig, configure: configure) { dependencies in
        AgentObservationDriver(dependencies: dependencies, coordinator: coordinator)
      }
    }
  }
#endif
