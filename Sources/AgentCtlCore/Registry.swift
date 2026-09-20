/// The runtime commands available on every screen, independent of any specific app.
public enum AgentRegistry {
  /// The `mock` example for a host that supplies no ``DocsText/mockExample`` of its own: a placeholder, because
  /// only the host knows what its clients are called.
  public static let defaultMockExample = "mock <client.method> <error>"

  /// - Parameter mockExample: the example in `mock`'s help, e.g. `mock orders.fetchOrders network`. The client
  ///   and method names are the host's, so it comes from ``DocsText/mockExample``.
  public static func runtimeCommands(mockExample: String = defaultMockExample) -> [CommandDoc] {
    [
      CommandDoc(
        name: "expect",
        argument: "k=v [k=v …]",
        help: "Assert on screen, any summary key, call=<client.method> (called during the previous step), "
          + "error=<code|none> or pending=<n>. A failed assertion fails the script.",
        source: "runtime"
      ),
      CommandDoc(
        name: "advance",
        argument: "<duration>",
        help: "Advance the test clock, e.g. 500ms, 30s, 5m, 1h. Headless only.",
        source: "runtime"
      ),
      CommandDoc(
        name: "mock",
        argument: "<client.method> <error>",
        help: "Make the next call to that method fail, e.g. \(mockExample).",
        source: "runtime"
      ),
    ]
  }

  /// Every command name across `screens`, including the runtime commands. The names do not depend on the
  /// host's `mock` example, so this needs none.
  public static func allCommandNames(screens: [ScreenDoc]) -> Set<String> {
    Set(screens.flatMap { $0.commands.map(\.name) } + runtimeCommands().map(\.name))
  }
}

/// Plain-text rendering for `<cli> screens`: the same command reference the generated document holds, so it
/// takes the same host-supplied ``DocsText/mockExample``.
public enum ScreensRenderer {
  public static func render(
    _ screens: [ScreenDoc],
    mockExample: String = AgentRegistry.defaultMockExample
  ) -> String {
    var lines: [String] = []
    for screen in screens {
      lines.append("\(screen.path)  [\(screen.screen)]")
      if screen.commands.isEmpty {
        lines.append("  (no screen commands)")
      }
      let width = max(24, (screen.commands.map(\.usage.count).max() ?? 0) + 2)
      for command in screen.commands {
        let source = command.source == screen.screen ? "" : "  (\(command.source))"
        let note = command.note.map { " [\($0)]" } ?? ""
        lines.append("  " + command.usage.padding(toLength: width, withPad: " ", startingAt: 0) + command.help + note + source)
      }
      if !screen.summaryKeys.isEmpty {
        lines.append("  summary: " + screen.summaryKeys.joined(separator: " "))
      }
    }
    lines.append("every screen  [runtime]")
    let runtimeCommands = AgentRegistry.runtimeCommands(mockExample: mockExample)
    let width = (runtimeCommands.map(\.usage.count).max() ?? 0) + 2
    for command in runtimeCommands {
      lines.append("  " + command.usage.padding(toLength: width, withPad: " ", startingAt: 0) + command.help)
    }
    return lines.joined(separator: "\n")
  }
}
