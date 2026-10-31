# TinyMVVM

[TinyApp](../TinyApp) rebuilt as MVVM-C: `@Observable` view models under a coordinator, no Composable Architecture.
It runs TinyApp's own scenario files, unchanged, and prints what TinyApp prints byte for byte. That is the proof that
the engine — the script language, `expect`, `advance`, `mock`, `device`, the step output — does not depend on how an
app is built.

TinyMVVM is its own package, depending on this repository by path, like AgentShop: Swift's `@Observable` needs iOS 17,
and AgentCtl itself supports iOS 16. Run everything from this directory:

```sh
swift run tinymvvmctl run "open 2; save"   # screen=items/2 title="Second item" saved=true cooldown=3 pending=1
swift run tinymvvmctl test                 # ../TinyApp/scenarios/*.appctl, on the MVVM-C app
swift run tinymvvmctl docs --check         # agent-commands.md is current
swift test                                 # TinyApp's transcripts on TinyMVVM, the coverage guards and scenario checks
```

## What is where

| File | What it shows |
|---|---|
| [`ItemsViewModel.swift`](Sources/TinyMVVM/ItemsViewModel.swift) | A screen as an `AgentViewModel`: `agentState`, summary, error, gated commands as `AgentScreenIntent`s, `onAppear` |
| [`ItemDetailViewModel.swift`](Sources/TinyMVVM/ItemDetailViewModel.swift) | A cooldown on the injected clock, and work cancelled on pop |
| [`AppCoordinator.swift`](Sources/TinyMVVM/AppCoordinator.swift) | The `AgentCoordinator`: navigation, the active screen, `back`, the registry, `cancelAllWork` |
| [`Config.swift`](Sources/TinyMVVM/Config.swift) | `AppCtlConfig<AgentObservationDriver<AppCoordinator>>`, its headless and live hosts, device links and pushes |
| [`ParityTests.swift`](Tests/TinyMVVMTests/ParityTests.swift) | Every script of [the fixture](Tests/TinyMVVMTests/Fixtures/tinyapp-transcripts.json) prints on TinyMVVM what it printed on TinyApp |

The fixture is TinyApp's side: the root package's `DriverParityTests` record it and fail when it is stale
(`APPCTL_RECORD=1 swift test --filter DriverParityTests` at the repository root rewrites it).

The rules a view model follows to stay deterministic are in
[the integration guide](../../docs/guides/integration.md#mvvm-c-apps-without-tca).
