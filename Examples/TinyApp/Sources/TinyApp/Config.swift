import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture

/// Everything AgentCtl needs to know about TinyApp: the facts the CLI would otherwise hard-code, the data the
/// docs are rendered from, and the two closures that build the app's store.
///
/// This is the whole integration. A host app writes one type like this, hands it to `AgentCtl.run(config:)` in
/// its own executable (see `Sources/tinyctl/main.swift`) and to `AgentLaunch(config:)` in its app shell.
public enum TinyAppConfig {
  /// Every screen an agent can reach, for `screens` and the generated docs.
  public static var screens: [ScreenDoc] { TinyRoot.registry }

  /// Every method `mock <method> <error>` accepts. The runner does not know the app's clients, so the config
  /// tells it.
  public static var mockMethods: [MockMethod] { ItemsClient.mockMethods }

  /// The prose around the generated command reference. Everything else in that document comes from the
  /// registry above.
  public static let docsText = DocsText(
    title: "TinyApp agent commands",
    intro: "TinyApp is the example app in this repository: a list, a detail screen and one mocked client.\n"
      + "Every screen is driven with the same commands, headlessly (`swift run tinyctl run \"…\"`) or from a\n"
      + "scenario file (`Examples/TinyApp/scenarios/*.appctl`).",
    usageExamples: [
      "swift run tinyctl run \"open 2; save\"                       # save the second item",
      "swift run tinyctl run \"open 2; save; advance 3s\"            # let the cooldown run out",
      "swift run tinyctl run \"mock items.fetch network; refresh\"   # make the next fetch fail",
      "swift run tinyctl test                                     # run every scenario",
    ],
    invocation: "swift run tinyctl",
    exampleCommand: "open 2",
    exampleStep: "screen=items/2 title=\"Second item\" saved=false cooldown=0",
    appendix: [
      "## The example's data",
      "",
      "`items.fetch` always returns three items: `First item`, `Second item` and `Third item`.",
      "A `save` starts a \(ItemDetail.cooldownSeconds)-second cooldown; saving again before it runs out reports",
      "`error=cooldown`. Headlessly, `advance \(ItemDetail.cooldownSeconds)s` runs the countdown out at once.",
    ]
  )

  /// The value `tinyctl` runs on.
  ///
  /// `target`, `bundleID`, `packages` and the simulator names describe a real app being built, run on a
  /// simulator and checked by the verification ladder. TinyApp has none of that — it is a package target with
  /// no Xcode project, driven headlessly — so those fields are honest placeholders and `tinyctl app …`,
  /// `tinyctl snapshots` and `tinyctl check` cannot work here. `target.path` is the one of them that is still
  /// used headlessly: it marks the repo root, which is how `test` finds `scenariosPath`, so it names the file
  /// that really does mark this package's root.
  @MainActor
  public static var appCtl: AppCtlConfig<TinyRoot> {
    AppCtlConfig(
      name: "TinyApp",
      target: .project("Package.swift", scheme: "TinyApp"),
      bundleID: "com.example.TinyApp",
      packages: ["TinyApp"],
      simulatorName: "iPhone 17 Pro",
      snapshotRuntimeMajor: 18,
      scenariosPath: "Examples/TinyApp/scenarios",
      help: HelpExamples(
        invocation: "swift run tinyctl",
        note: "TinyApp is this repository's example app; it runs headlessly, with no simulator.",
        runScripts: ["open 2; save", "refresh", "expect screen=items items=3"],
        sessionPath: ".appctl/tiny.session",
        scenarioPath: "Examples/TinyApp/scenarios/browse.appctl",
        appSeeds: ["open 2", "refresh; open 2"],
        appScripts: ["open 2; expect saved=false", "save"]
      ),
      mockMethods: mockMethods,
      docsText: docsText,
      screens: screens,
      makeHeadless: { headless() },
      makeLive: { latency in live(latency: latency) },
      // TinyApp keeps nothing between launches, so there is no saved session to forget.
      clearSession: {}
    )
  }

  /// A deterministic store on the Mac: a `TestClock`, incrementing UUIDs, a fixed date and zero mock latency.
  /// `tinyctl run`, `tinyctl test` and the package's own tests all run against this.
  @MainActor
  public static func headless() -> HeadlessHost<TinyRoot> {
    HeadlessHost(initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, mockMethods: mockMethods) { deps, _ in
      // The client's `liveValue` is the mock. Bind it explicitly, so the app behaves the same in a test
      // process, where dependencies otherwise default to their unimplemented test values.
      deps.itemsClient = .liveValue
    }
  }

  /// The store the app would run in a DEBUG build behind AgentCtlBridge: real time and real mock latency.
  @MainActor
  public static func live(latency: MockLatency) -> LiveHost<TinyRoot> {
    LiveHost(
      initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, latency: latency, mockMethods: mockMethods
    ) { deps, _ in
      deps.itemsClient = .liveValue
    }
  }
}
