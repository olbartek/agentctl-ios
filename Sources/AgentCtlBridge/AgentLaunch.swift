#if DEBUG
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation
  import Observation

  /// Starts the agent bridge in DEBUG builds of a SwiftUI app and applies launch seeding.
  ///
  /// Everything app-specific comes from the ``AppCtlConfig`` the host hands it — the same value its CLI runs
  /// on — so the app shell's integration is one line:
  ///
  /// ```swift
  /// @State private var launch = AgentLaunch(config: MyAppConfig.appCtl)
  /// ```
  ///
  /// It is an ``AgentLaunchSession`` whose ``app`` and ``isReady`` a SwiftUI view observes, which is why it needs
  /// iOS 17. A UIKit app, or an app on iOS 16, uses the session itself. The launch arguments are those of
  /// ``AgentLaunchOptions`` (CONTRACT.md §8.2).
  @available(iOS 17, macOS 14, *)
  @MainActor
  @Observable
  public final class AgentLaunch<Driver: AgentDriver> {
    /// The launch arguments; the name they had before 0.11, when they lived here.
    public typealias Options = AgentLaunchOptions

    /// Whether this launch asks for the bridge: it passed a well-formed `-agent-token`, as the CLI's `app` subcommands
    /// always do and ⌘R from Xcode does not. An app shell that should run as the plain app over its live
    /// dependencies unless an agent launched it checks this before creating an `AgentLaunch`:
    ///
    /// ```swift
    /// if AgentLaunchArguments.isRequested() { … AgentLaunch(config: MyAppConfig.appCtl) … } else { … }
    /// ```
    public nonisolated static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
      AgentLaunchArguments.isRequested(arguments)
    }

    /// The session this wraps: the bridge, the live host and the seed.
    @ObservationIgnored public let session: AgentLaunchSession<Driver>
    public var options: AgentLaunchOptions { session.options }
    /// What the root view shows — the store of a TCA app, the coordinator of an MVVM-C app. `device relaunch`
    /// replaces it, and the root view rebuilds on the new one.
    public private(set) var app: Driver.App
    /// The name ``app`` had before 0.7, when every app was a TCA store.
    @available(*, deprecated, renamed: "app")
    public var store: Driver.App { app }
    /// `false` while a launch seed is being applied.
    public private(set) var isReady: Bool

    public init(config: AppCtlConfig<Driver>, arguments: [String] = ProcessInfo.processInfo.arguments) {
      let session = AgentLaunchSession(config: config, arguments: arguments)
      self.session = session
      self.app = session.app
      self.isReady = session.isReady
      session.onAppChange = { [weak self] app in self?.app = app }
      session.onReady = { [weak self] in self?.isReady = true }
    }

    /// Applies the seed (if any), then starts the bridge, so the bridge's first answer means the app is ready.
    /// Call once, from the root view's `.task`.
    public func start() async {
      await session.start()
    }

    /// Whether the bridge is listening.
    var isListening: Bool { session.isListening }

    /// Stops the bridge. Tests only: an app's bridge lives as long as the app.
    func stop() {
      session.stop()
    }

    /// ``AgentLaunchSession``'s seed, under the name the tests have always used.
    static func applySeed(
      _ seed: String, with runner: ScriptRunner<Driver>
    ) async throws(CancellationError) -> (status: RunStatus, log: String) {
      try await AgentLaunchSession<Driver>.applySeed(seed, with: runner)
    }
  }
#endif
