#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import ArgumentParser
  import ComposableArchitecture
  import Foundation
  import Synchronization

  /// The host's example commands and invocation, for every string the CLI prints that names the CLI itself.
  /// Computed, not stored: ``AgentCtl/runtime`` is set by ``AgentCtl/run(config:)``, which happens before any
  /// `CommandConfiguration` or message is read.
  var help: HelpExamples { AgentCtl.runtime.help }

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

    /// Runs the CLI against `config`. Called from the host executable's `main.swift`. It returns when the command
    /// succeeded, and otherwise exits the process with the command's exit code (CONTRACT.md §5).
    public static func run<Root>(config: AppCtlConfig<Root>) async
    where
      Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
      Root.AgentState == Root.State, Root.AgentAction == Root.Action
    {
      install(ErasedConfig(config: config))
      // What `AsyncParsableCommand.main()` does, except for the exit code of a usage error: see ``exitStatus(for:)``.
      do {
        var command = try await AppCtlCommand.asyncParseAsRoot()
        if var asyncCommand = command as? AsyncParsableCommand {
          try await asyncCommand.run()
        } else {
          try command.run()
        }
      } catch {
        let status = exitStatus(for: error)
        let message = AppCtlCommand.fullMessage(for: error)
        if !message.isEmpty {
          // Help goes to stdout; every error, usage errors included, goes to stderr — as ArgumentParser does it.
          if status == 0 {
            print(message)
          } else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
          }
        }
        exit(status)
      }
    }

    /// The exit code for an error thrown while parsing or running a command.
    ///
    /// ArgumentParser exits 64 (`EX_USAGE`) for its own usage errors — a missing argument, an unknown option or
    /// subcommand, a failed validation. The contract has one code for every usage error, 2 (CONTRACT.md §5), so
    /// those map to 2. Everything else keeps ArgumentParser's code: 0 for `--help`, and the code a subcommand
    /// throws as an `ExitCode` for its own failures.
    static func exitStatus(for error: any Error) -> Int32 {
      let code = AppCtlCommand.exitCode(for: error)
      return code == .validationFailure ? RunStatus.usage.rawValue : code.rawValue
    }

    /// Installs the host's facts without running a command. ``run(config:)`` calls it; the package's own tests
    /// call it to render the help pages and messages that must carry the host's own invocation.
    static func install(_ runtime: any AppCtlRuntime) {
      box.withLock { $0 = runtime }
    }
  }
#endif
