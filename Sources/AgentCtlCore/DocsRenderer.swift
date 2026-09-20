import Foundation

/// The host-written prose in `docs/agent-commands.md`: everything that is not generated from the registry.
public struct DocsText: Sendable {
  public var title: String
  public var intro: String
  public var usageExamples: [String]
  /// A single rendered step, shown as a worked example of the script syntax's output, e.g.
  /// `screen=<path> <key>=<value> … calls=<client.method>,…`. Hosts should supply one of their own,
  /// built from a real screen, in place of the generic default.
  public var exampleStep: String
  public var appendix: [String]

  public init(
    title: String,
    intro: String,
    usageExamples: [String],
    exampleStep: String = "screen=<path> <key>=<value> … calls=<client.method>,…",
    appendix: [String]
  ) {
    self.title = title
    self.intro = intro
    self.usageExamples = usageExamples
    self.exampleStep = exampleStep
    self.appendix = appendix
  }
}

/// Renders `docs/agent-commands.md` from data. The output depends only on its inputs, so `docs --check` can
/// compare it byte for byte.
public enum DocsRenderer {
  public static func render(
    screens: [ScreenDoc],
    runtimeCommands: [CommandDoc],
    mockMethods: [MockMethod],
    text: DocsText
  ) -> String {
    var out: [String] = []
    out.append("# \(text.title)")
    out.append("")
    out.append("> **GENERATED** by `./appctl docs` from the `+Agent.swift` files. Do not edit by hand; run `./appctl docs` instead.")
    out.append("")
    out.append(text.intro)
    out.append("")
    out.append("## Script syntax")
    out.append("")
    out.append("- Commands are separated by `;` or newlines. `#` starts a comment.")
    out.append("- A command's argument is the rest of the line: `<command> a value with spaces`.")
    out.append("- Double quotes protect `;` and `#`: `<command> \"a;b#c\"`. Inside quotes, `\\\"` is a quote.")
    out.append("- After each command the app settles and one step is printed:")
    out.append("")
    out.append("  ```text")
    out.append("  > submit")
    out.append("    \(text.exampleStep)")
    out.append("  ```")
    out.append("")
    out.append("  The line holds `screen`, the screen's summary keys, `calls=` (mock calls made during the step),")
    out.append("  `error=` (if set) and `pending=` (effects waiting on the clock, e.g. a countdown; headlessly")
    out.append("  `advance <duration>` releases them).")
    out.append("- Exit codes: `0` all steps passed, `1` a command or `expect` failed, `2` usage or parse error, `3` internal error.")
    out.append("")
    out.append("## Examples")
    out.append("")
    out.append("```bash")
    out.append(contentsOf: text.usageExamples)
    out.append("```")
    out.append("")
    out.append("Scenarios in `scenarios/*.appctl` use the same syntax plus `expect` lines; `./appctl test` runs them.")
    out.append("")
    out.append("## Runtime commands (every screen)")
    out.append("")
    out.append("| Command | Description |")
    out.append("|---|---|")
    for command in runtimeCommands {
      out.append("| `\(escape(command.usage))` | \(escape(command.help)) |")
    }
    out.append("")
    out.append("## Screens")
    out.append("")
    for screen in screens {
      out.append("### `\(screen.path)`")
      out.append("")
      out.append("Screen: `\(screen.screen)`.")
      if !screen.summaryKeys.isEmpty {
        out.append("Summary keys: " + screen.summaryKeys.map { "`\($0)`" }.joined(separator: ", ") + ".")
      }
      out.append("")
      if screen.commands.isEmpty {
        out.append("No screen commands; only the runtime commands apply.")
      } else {
        out.append("| Command | Description | From |")
        out.append("|---|---|---|")
        for command in screen.commands {
          let note = command.note.map { " *(\(escape($0)))*" } ?? ""
          out.append("| `\(escape(command.usage))` | \(escape(command.help))\(note) | \(command.source) |")
        }
      }
      out.append("")
    }
    out.append("## Mockable methods")
    out.append("")
    out.append("`mock <method> <error>` makes the next call to the method throw that error.")
    out.append("")
    out.append("| Method | Errors |")
    out.append("|---|---|")
    for method in mockMethods {
      out.append("| `\(method.name)` | " + method.errorCodes.map { "`\($0)`" }.joined(separator: ", ") + " |")
    }
    out.append("")
    out.append(contentsOf: text.appendix)
    out.append("")
    return out.joined(separator: "\n")
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "|", with: "\\|")
  }
}
