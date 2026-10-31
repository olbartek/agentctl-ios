# Overview

What AgentCtl is for, what it needs, what it ships and its example apps.

## How much faster

[`Examples/AgentShop`](../../Examples/AgentShop) (sign-in, onboarding, a shop) has 99 scenarios that run unchanged in
three modes: headlessly, through the bridge in the real app on a simulator, and as XCUITests generated from the
same files. On an Apple M4 Max, with an iPhone 17 Pro simulator:

| | Headless | Simulator, via the bridge | XCUITest |
|---|---|---|---|
| All 99 scenarios (1,104 steps) | **1.3 s** | 8 min 2 s | 30 min 8 s |
| A typical 12-step scenario | **18 ms** | 5.1 s | 18.4 s |
| Change a line of a reducer, then check it | **1.6 s** | — | 35.2 s |

Headless has nothing to wait for: no simulator, no app to launch, no views, and a test clock instead of real
time. The bridge pays for a real app, a launch per scenario and a 250 ms quiet window per command; the UI tests
also pay for a second process that finds every element through accessibility, types key by key and waits for
every animation. [The full report](../benchmarks/2026-09-24-agentshop.md) explains where the time goes, and
[this video](../benchmarks/2026-09-24-agentshop.mp4) runs three scenarios side by side. The same 99 scenarios on
Android, in [the Kotlin port](https://github.com/olbartek/agentctl-android/wiki/Home#how-much-faster), take 291 ms headlessly,
5 min 48 s through the bridge on an emulator and 5 min 12 s as Compose UI tests.

The modes check different things, so this is not a case for deleting UI tests: the generated UI tests found a
place where the headless run disagreed with iOS. It is a case for which one an agent runs hundreds of times a day.

## Requirements, and what this is not

- **macOS 15+ and a Swift 6.1+ toolchain** (`swift-tools-version: 6.1`; developed and verified on Swift 6.3,
  Xcode 26.6). The libraries support iOS 16+ as well (a SwiftUI shell's `AgentLaunch`, which is `@Observable`, needs
  iOS 17; `AgentLaunchSession` does not); the CLI is macOS-only, see below.
- **The app is built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)**
  (1.26+), **or as MVVM-C**: `@Observable` view models under a coordinator, with their dependencies from
  [swift-dependencies](https://github.com/pointfreeco/swift-dependencies). The engine talks to an `AgentDriver`, never
  to your app's types; `AgentCtlTCA` drives a store, `AgentCtlObservation` drives a coordinator, and both run the same
  scripts with the same output (see [MVVM-C](integration.md#mvvm-c-apps-without-tca)).
- **Screens are driven through state, not through the UI.** Nothing taps and nothing reads pixels; a headless
  run has no views at all. Rendering is verified separately, by snapshot tests (see
  [the ladder](verification-ladder.md)).
- **The CLI cannot ship as a prebuilt binary.** It links your reducers: it builds your app's store in its own
  process and sends your actions to it. So `AgentCtlCLI` is a *library*, and each host compiles a small
  executable — an import, its `AppCtlConfig`, one call — that becomes its own CLI. That executable is macOS-only
  because it shells out to `xcodebuild`, `simctl` and SwiftPM, which is why every file in `AgentCtlCLI` is
  wrapped in `#if os(macOS)`: building the package for an iOS destination compiles that target to nothing
  instead of failing.

## Packages

### What this package provides

Take only the products each target needs. Everything but `AgentCtlCore` compiles to nothing in a Release build, so
only the screens' agent surface ships.

| Product | What it is for | Who depends on it | In a Release build |
|---|---|---|---|
| `AgentCtlCore` | The vocabulary: `AgentScreen`, commands and their gates, `AgentViewModel`, the script parser, `expect`, mocked calls and faults, the simulated device | your features' `+Agent.swift` files | ships |
| `AgentCtlRuntime` | The engine: `ScriptRunner`, settling, the headless and live hosts, `AppCtlConfig`, the deterministic executor | your config module | compiled away |
| `AgentCtlTCA` | `AgentStoreDriver`: drives a Composable Architecture store | the config module of a TCA app | compiled away |
| `AgentCtlObservation` | `AgentObservationDriver`: drives view models under an `AgentCoordinator` (MVVM-C, no TCA) | the config module of an MVVM-C app | compiled away |
| `AgentCtlBridge` | The in-app bridge: `AgentLaunch` (SwiftUI, iOS 17+), `AgentLaunchSession` (UIKit or iOS 16), the token-checked HTTP server on `127.0.0.1` | the app shell, in `#if DEBUG` | compiled away |
| `AgentCtlCLI` | The CLI as a library: `run`, `test`, `docs`, `check`, `app …`, `device …`; macOS only | your CLI executable (4 lines) | not linked by the app |
| `AgentCtlTestSupport` | `AgentCoverage` and `AgentScenarioChecks`: the guards that fail a build when the agent surface drifts | your test targets | not linked by the app |

### What it depends on

| Package | Used by | What for |
|---|---|---|
| [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) | `AgentCtlCore`, `AgentCtlRuntime`, `AgentCtlObservation` | The `@Dependency` values a headless run swaps: the clock, mocked clients, the simulated device |
| [swift-clocks](https://github.com/pointfreeco/swift-clocks) | `AgentCtlRuntime` | `TestClock`: a headless run's time, which `advance` moves instead of waiting |
| [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | `AgentCtlRuntime` | The main serial executor, which makes a headless run's task scheduling deterministic |
| [swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture) | `AgentCtlTCA` (and TinyApp, AgentShop) | The store `AgentStoreDriver` drives; only a TCA app links it |
| [swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump) | `AgentCtlObservation` | Diffing two dumps of the view models' state, to show what a step changed |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | `AgentCtlCLI` | The CLI's commands, options and help pages |

Apple's own frameworks fill in the rest: Network for the bridge's listener, Security for its token, Observation for
`AgentLaunch`, AVFoundation for the CLI's recordings.

## The example apps

[`Examples/TinyApp`](../../Examples/TinyApp) is the smallest complete integration and this package's fixture: two screens,
one mocked client, five scenarios, its own `tinyctl` executable and a committed
[generated command reference](../../Examples/TinyApp/agent-commands.md). See
[its README](../../Examples/TinyApp/README.md), or just run it:

```bash
swift run tinyctl run "open 2; save; advance 3s"
swift run tinyctl test
swift test          # this package's own suite, driven against TinyApp
```

[`Examples/TinyMVVM`](../../Examples/TinyMVVM) is TinyApp rebuilt as MVVM-C, with no TCA. It runs TinyApp's scenario files
unchanged and prints the same output byte for byte (`swift run tinymvvmctl test` in its directory). It is its own
package, depending on this one by path, because Swift's `@Observable` needs iOS 17. See
[its README](../../Examples/TinyMVVM/README.md).

[`Examples/AgentShop`](../../Examples/AgentShop) is the showcase: a real iOS app (sign-in, onboarding, a shop with a
cart and checkout) with an Xcode project, 123 scenarios, UI tests generated from them, and the benchmark behind
[the numbers above](#how-much-faster). It is its own package, depending on this one by path. See
[its README](../../Examples/AgentShop/README.md).

## Building this repository

Everything builds and tests with SwiftPM on a Mac: `swift test` at the root runs this package's suite against TinyApp,
and `swift run tinyctl test` runs TinyApp's scenarios. The two other example apps are packages of their own, built from
their directories (`Examples/TinyMVVM`, `Examples/AgentShop`). They depend on this one by path, and a path
dependency's identity is its directory's name, so build them from a checkout whose directory is named
`agentctl-ios`. The full list of checks a change passes before it merges, the iOS 16 build and the release builds
included, is in [AGENTS.md](../../AGENTS.md#verifying-a-change).
