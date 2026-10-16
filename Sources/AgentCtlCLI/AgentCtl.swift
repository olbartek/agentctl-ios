#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCore
  import AgentCtlRuntime
  import ArgumentParser
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
    public static func run<Driver>(config: AppCtlConfig<Driver>) async {
      install(ErasedConfig(config: config))
      // What `AsyncParsableCommand.main()` does, except for the exit code of a usage error: see ``exitStatus(for:)``.
      do {
        var command = try await AppCtlCommand.asyncParseAsRoot(arguments(Array(CommandLine.arguments.dropFirst())))
        if let usage = missingSubcommand(command) {
          FileHandle.standardError.write(Data((usage + "\n").utf8))
          exit(RunStatus.usage.rawValue)
        }
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

    /// The command line as ArgumentParser should read it. `app location -33.86,151.20` (a southern latitude) would
    /// read as an option, so a value that starts with `-` and a digit moves behind a `--`, where it is the argument;
    /// the options around it keep working.
    static func arguments(_ arguments: [String]) -> [String] {
      guard arguments.starts(with: ["app", "location"]), !arguments.contains("--"),
        let index = arguments.indices.dropFirst(2).first(where: { arguments[$0].firstMatch(of: #/^-\.?[0-9]/#) != nil })
      else { return arguments }
      var moved = arguments
      let value = moved.remove(at: index)
      return moved + ["--", value]
    }

    /// The help of a command group run without a subcommand (`appctl`, `appctl app`), or `nil` for any other
    /// command. ArgumentParser prints a group's help and exits 0 for it, as if `--help` had been asked; but a
    /// missing subcommand is a malformed command line, so the CLI prints that help on stderr and exits 2
    /// (CONTRACT.md §5), as a script's `device` line with no subcommand does. `--help`, `-h` and `help` still print
    /// it on stdout and exit 0: they parse to ArgumentParser's own help command, never to the group.
    static func missingSubcommand(_ command: any ParsableCommand) -> String? {
      let group = type(of: command)
      guard !group.configuration.subcommands.isEmpty else { return nil }
      return AppCtlCommand.helpMessage(for: group)
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
