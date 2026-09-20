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
    scenariosGlob: "Examples/TinyApp/scenarios/*.appctl",
    appendix: [
      "## The example's data",
      "",
      "`items.fetch` always returns three items: `First item`, `Second item` and `Third item`.",
      "A `save` starts a \(ItemDetail.cooldownSeconds)-second cooldown; saving again before it runs out reports",
      "`error=cooldown`. Headlessly, `advance \(ItemDetail.cooldownSeconds)s` runs the countdown out at once.",
      "`open <id>` with an id the list does not have reports `error=notFound` instead of doing nothing.",
    ]
  )

  /// The value `tinyctl` runs on.
  ///
  /// TinyApp is a package target driven headlessly: there is no Xcode project to build and no app bundle to
  /// install, so `target`, `bundleID`, `packages` and the simulator names have nothing real to name here, and
  /// `tinyctl app …`, `tinyctl snapshots` and `tinyctl check` cannot work. Everything the example does
  /// demonstrate — `run`, `state`, `screens`, `docs`, `test` — needs none of them.
  @MainActor
  public static var appCtl: AppCtlConfig<TinyRoot> {
    AppCtlConfig(
      name: "TinyApp",
      // A real host writes `.workspace("MyApp.xcworkspace", scheme: "MyApp")`, or `.project` for a project.
      // There is nothing to build here, and a placeholder says so where a fake file name would not.
      target: .project("<none: TinyApp has no Xcode project>", scheme: "TinyApp"),
      // The CLI finds the repo root by walking up for a marker, and resolves `scenariosPath` and the generated
      // docs against it. With no project to look for, name the file that really does mark this package's root.
      // A host with an Xcode project omits this: the marker is its `target` path.
      rootMarker: "Package.swift",
      bundleID: "com.example.TinyApp",
      // `check` builds and tests `Packages/<name>` for each of these, a layout the example does not have.
      packages: ["TinyApp"],
      simulatorName: "iPhone 17 Pro",
      snapshotRuntimeMajor: 18,
      scenariosPath: "Examples/TinyApp/scenarios",
      // The app is not at the root of its repository, so its command reference lives beside it rather than in
      // the package's own `docs/`. `tinyctl docs` writes it; `tinyctl docs --check` fails when it is stale.
      docsPath: "Examples/TinyApp/agent-commands.md",
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
