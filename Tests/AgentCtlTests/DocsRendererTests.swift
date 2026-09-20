import AgentCtlCore
import Testing

/// What this guards: the prose ``DocsRenderer`` wraps around a host's data. Every line of it must be either
/// generic or filled from ``DocsText``, because it is rendered into each host's committed
/// `docs/agent-commands.md` — where naming another app's CLI or commands tells that host's agents to run things
/// that do not exist.
///
/// What it does not guard: the screen, command and mock tables, which are the host's own data.
@Suite
struct DocsRendererTests {
  static func render(_ text: DocsText) -> String {
    DocsRenderer.render(screens: [], runtimeCommands: AgentRegistry.runtimeCommands, mockMethods: [], text: text)
  }

  @Test
  func theRenderedProseNamesNoHostApp() {
    let markdown = Self.render(
      DocsText(title: "Docs", intro: "An app.", usageExamples: [], invocation: "xctl", appendix: [])
    )
    // `.appctl` (the scenario file extension) and `-appctl-seed` (the app's launch argument) are fixed tokens,
    // not the CLI's name; anything else spelling `appctl` would be this package naming its own PoC.
    let stripped = markdown
      .replacingOccurrences(of: ".appctl", with: "")
      .replacingOccurrences(of: "-appctl-seed", with: "")
    #expect(!stripped.contains("appctl"))
    for word in ["alice", "login-as", "home/orders", "auth.login", "Alice Smith", "password \"", "> submit"] {
      #expect(!markdown.contains(word), "the generated docs still name '\(word)'")
    }
    // Not vacuous: the host's invocation and the placeholder command really are rendered.
    #expect(markdown.contains("`xctl docs`"))
    #expect(markdown.contains("`xctl test`"))
    #expect(markdown.contains("  > <command>"))
  }

  /// The claim Task 14 depends on: a host that fills every field gets its own wording back byte for byte, so its
  /// committed docs differ only where this package deliberately generalized the prose (the two script-syntax
  /// bullets, which are placeholders on purpose).
  @Test
  func aHostRestoresItsOwnWording() {
    let text = DocsText(
      title: "Agent commands",
      intro: "Every screen can be driven with the same commands.",
      usageExamples: [],
      invocation: "./appctl",
      exampleCommand: "submit",
      exampleStep: "screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders",
      appendix: []
    )
    let lines = Self.render(text).components(separatedBy: "\n")
    #expect(
      lines.contains(
        "> **GENERATED** by `./appctl docs` from the `+Agent.swift` files. Do not edit by hand; "
          + "run `./appctl docs` instead."
      )
    )
    #expect(lines.contains("  > submit"))
    #expect(lines.contains("    screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders"))
    #expect(
      lines.contains(
        "Scenarios in `scenarios/*.appctl` use the same syntax plus `expect` lines; `./appctl test` runs them."
      )
    )
  }
}
