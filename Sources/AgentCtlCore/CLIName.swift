import Foundation

/// How this process names the CLI it is running: the executable's own name, so a host's `tinyctl` calls itself
/// `tinyctl` in its help and in the documentation it generates.
///
/// It is the default for ``DocsText/invocation`` and for `HelpExamples.invocation`; a host whose repo wraps the
/// binary in a script sets those to the wrapper's spelling (`./appctl`) instead.
public enum CLIName {
  public static var current: String {
    URL(fileURLWithPath: CommandLine.arguments.first ?? "appctl").lastPathComponent
  }
}
