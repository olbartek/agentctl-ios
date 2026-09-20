import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Synchronization

/// The CLI as a library: a host's executable hands it an ``AppCtlConfig`` and AgentCtl runs the same commands
/// against that app.
///
/// ```swift
/// // main.swift
/// await AgentCtl.run(config: MyAppConfig.appCtl)
/// ```
public enum AgentCtl {
  /// The CLI's one piece of global state. ArgumentParser's command types are static — they build their
  /// `CommandConfiguration`s and option defaults before any instance exists — so they read the host's config
  /// from here instead of taking it as an argument. ``run(config:)`` assigns it exactly once, before the first
  /// argument is parsed, and nothing writes it again.
  private static let box = Mutex<(any AppCtlRuntime)?>(nil)

  /// The config ``run(config:)`` was called with.
  static var runtime: any AppCtlRuntime {
    guard let runtime = box.withLock({ $0 }) else {
      fatalError("AgentCtl.runtime was read before AgentCtl.run(config:) set it")
    }
    return runtime
  }

  /// Runs the CLI against `config`. Called from the host executable's `main.swift`; it does not return.
  public static func run<Root>(config: AppCtlConfig<Root>) async
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    box.withLock { $0 = ErasedConfig(config: config) }
    await AppCtlCommand.main()
  }
}
