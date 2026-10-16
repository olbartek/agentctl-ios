// Like AgentCtlObservation, which it builds on: debug builds only. A host's config module does the same.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import AgentCtlObservation
  import Dependencies
  import Foundation

  /// TinyMVVM's integration: TinyApp rebuilt as MVVM-C — `@Observable` view models under a coordinator, no TCA — and
  /// driven through an `AgentObservationDriver`. It runs TinyApp's own scenario files and prints what TinyApp prints.
  public enum TinyMVVMConfig {
    public static var screens: [ScreenDoc] { AppCoordinator.registry }

    public static var mockMethods: [MockMethod] { ItemsClient.mockMethods }

    /// The same links and push as TinyApp's, as intents on the coordinator.
    public static var device: AgentDeviceConfig<AgentIntent<AppCoordinator>> {
      AgentDeviceConfig(
        openURL: { url in
          guard url.scheme == "tinyapp", url.host == "items", url.pathComponents.count == 2,
            let id = Int(url.pathComponents[1])
          else { return nil }
          return AgentIntent { $0.openItem(id) }
        },
        pushes: [
          AgentDevice.Push(
            "item-updated", help: "Item 2 was updated.",
            received: AgentIntent { $0.items.refresh() }, opened: AgentIntent { $0.openItem(2) }
          )
        ]
      )
    }

    public static let docsText = DocsText(
      title: "TinyMVVM agent commands",
      intro: "TinyMVVM is TinyApp rebuilt as MVVM-C: `@Observable` view models under a coordinator, no TCA.\n"
        + "It is driven with the same commands, and runs TinyApp's scenario files (`Examples/TinyApp/scenarios/*.appctl`).",
      usageExamples: [
        "swift run tinymvvmctl run \"open 2; save\"                       # save the second item",
        "swift run tinymvvmctl test                                     # TinyApp's scenarios, on the MVVM-C app",
      ],
      invocation: "swift run tinymvvmctl",
      exampleCommand: "open 2",
      exampleStep: "screen=items/2 title=\"Second item\" saved=false cooldown=0",
      scenariosGlob: "Examples/TinyApp/scenarios/*.appctl",
      mockExample: "mock items.fetch network",
      appendix: []
    )

    @MainActor
    public static var appCtl: AppCtlConfig<AgentObservationDriver<AppCoordinator>> {
      AppCtlConfig(
        name: "TinyMVVM",
        target: .project("<none: TinyMVVM has no Xcode project>", scheme: "TinyMVVM"),
        rootMarker: "Package.swift",
        bundleID: "com.example.TinyMVVM",
        packages: ["."],
        simulatorName: "iPhone 17 Pro",
        snapshotRuntimeMajor: 18,
        // TinyApp's scenarios: the point of this example is that they pass unchanged.
        scenariosPath: "Examples/TinyApp/scenarios",
        docsPath: "Examples/TinyMVVM/agent-commands.md",
        help: HelpExamples(
          invocation: "swift run tinymvvmctl",
          note: "TinyMVVM is TinyApp as MVVM-C; it runs headlessly, with no simulator.",
          runScripts: ["open 2; save", "refresh", "expect screen=items items=3"],
          sessionPath: ".appctl/tinymvvm.session",
          scenarioPath: "Examples/TinyApp/scenarios/browse.appctl",
          appSeeds: ["open 2", "refresh; open 2"],
          appScripts: ["open 2; expect saved=false", "save"]
        ),
        mockMethods: mockMethods,
        device: device,
        docsText: docsText,
        screens: screens,
        makeHeadless: { headless() },
        makeLive: { latency in live(latency: latency) },
        clearSession: {}
      )
    }

    /// A deterministic app on the Mac: a `TestClock`, a fixed date, and everything else `HeadlessHost` pins.
    @MainActor
    public static func headless(device: AgentDeviceConfig<AgentIntent<AppCoordinator>> = device)
      -> HeadlessHost<AgentObservationDriver<AppCoordinator>>
    {
      HeadlessHost(mockMethods: mockMethods, device: device) { deps, _ in
        deps.itemsClient = .liveValue
      } coordinator: {
        AppCoordinator()
      }
    }

    /// The app as it would run behind AgentCtlBridge in a DEBUG build: real time and real mock latency.
    @MainActor
    public static func live(latency: MockLatency) -> LiveHost<AgentObservationDriver<AppCoordinator>> {
      LiveHost(latency: latency, mockMethods: mockMethods, device: device) { deps, _ in
        deps.itemsClient = .liveValue
      } coordinator: {
        AppCoordinator()
      }
    }
  }
#endif
