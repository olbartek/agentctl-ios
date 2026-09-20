import AgentCtlTCA
import Testing

/// The CLI's help examples come from the host's config. These assertions are about the defaults a host gets
/// when it supplies none: they must describe no particular app, because they ship in this package.
@Suite
struct HelpExamplesTests {
  @Test
  func defaultsNameNoHostApp() {
    let help = HelpExamples()
    let text = ([help.invocation, help.sessionPath, help.scenarioPath ?? ""] + help.runScripts + help.appSeeds
      + help.appScripts).joined(separator: " ")
    #expect(help.note == nil)
    #expect(help.scenarioPath == nil)
    // Placeholders only: every example is either a `<…>` placeholder or a command this package itself defines.
    for word in ["alice", "bob", "login-as", "orders", "profile", "auth/", "home/", "cancel"] {
      #expect(!text.contains(word), "the default help examples mention '\(word)'")
    }
    #expect(text.contains("<command>"))
  }

  /// A host that supplies fewer examples than a subcommand shows must still get a printable placeholder,
  /// never a crash from indexing past the end.
  @Test
  func accessorsFallBackToAPlaceholder() {
    let help = HelpExamples(runScripts: ["refresh"], appSeeds: [], appScripts: ["open 1"])
    #expect(help.runScript(0) == "refresh")
    #expect(help.runScript(2) == "<command>")
    #expect(help.appSeed(0) == "<command>")
    #expect(help.appScript(0) == "open 1")
    #expect(help.appScript(1) == "<command>")
  }

  @Test
  func defaultInvocationIsTheExecutablesOwnName() {
    let invocation = HelpExamples.defaultInvocation
    #expect(!invocation.isEmpty)
    #expect(!invocation.contains("/"))
  }
}
