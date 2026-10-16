# AgentCtl

AgentCtl makes an app **agent-addressable**. Every screen describes itself — a path such as `items/<id>`, a
compact `key=value` summary, an error code, and the commands it offers — and a CLI drives those commands from
the terminal, *headlessly on a Mac with no simulator*, printing one line of state per step. A coding agent (or
you) can open a screen, run a command and assert on the result in milliseconds, instead of building the app,
booting a simulator and guessing whether a tap landed. The same script also drives the real app on a simulator
through a DEBUG-only in-app bridge, so what you assert headlessly is what the app does.

```
$ swift run tinyctl run "open 2; save"
> (launch)
  screen=items items=3 loading=false calls=items.fetch
> open 2
  screen=items/2 title="Second item" saved=false cooldown=0
> save
  screen=items/2 title="Second item" saved=true cooldown=3 pending=1
```

That is the whole idea: `screen=` is where you are, the pairs after it are what the screen says about itself,
`calls=` is which mocked client methods were called during the step, and `pending=1` is one effect suspended on
the clock — here the three-second save cooldown, which `advance 3s` runs out at once instead of waiting.

Scripts can assert, so they can be committed as executable specifications:

```
open 2
expect screen=items/2 cooldown=0 error=none
save
expect saved=true cooldown=3 pending=1 error=none
save
expect error=cooldown saved=true cooldown=3 pending=1
advance 1s
expect cooldown=2 pending=1 error=cooldown
```

— from [`Examples/TinyApp/scenarios/save-cooldown.appctl`](Examples/TinyApp/scenarios/save-cooldown.appctl), run
by `tinyctl test` and by this package's own test suite.

## How much faster

[`Examples/AgentShop`](Examples/AgentShop) (sign-in, onboarding, a shop) has 99 scenarios that run unchanged in
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
every animation. [The full report](docs/benchmarks/2026-09-24-agentshop.md) explains where the time goes, and
[this video](docs/benchmarks/2026-09-24-agentshop.mp4) runs three scenarios side by side. The same 99 scenarios on
Android, in [the Kotlin port](https://github.com/olbartek/agentctl-android#how-much-faster), take 291 ms headlessly,
5 min 48 s through the bridge on an emulator and 5 min 12 s as Compose UI tests.

The modes check different things, so this is not a case for deleting UI tests: the generated UI tests found a
place where the headless run disagreed with iOS. It is a case for which one an agent runs hundreds of times a day.

## Requirements, and what this is not

- **macOS 15+ and a Swift 6.1+ toolchain** (`swift-tools-version: 6.1`; developed and verified on Swift 6.3,
  Xcode 26.6). The library targets support iOS 18+ as well; the CLI is macOS-only, see below.
- **The app is built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)**
  (1.26+), **or as MVVM-C**: `@Observable` view models under a coordinator, with their dependencies from
  [swift-dependencies](https://github.com/pointfreeco/swift-dependencies). The engine talks to an `AgentDriver`, never
  to your app's types; `AgentCtlTCA` drives a store, `AgentCtlObservation` drives a coordinator, and both run the same
  scripts with the same output (see [MVVM-C](docs/guides/integration.md#mvvm-c-apps-without-tca)).
- **Screens are driven through state, not through the UI.** Nothing taps and nothing reads pixels; a headless
  run has no views at all. Rendering is verified separately, by snapshot tests (see
  [the ladder](docs/guides/verification-ladder.md)).
- **The CLI cannot ship as a prebuilt binary.** It links your reducers: it builds your app's store in its own
  process and sends your actions to it. So `AgentCtlCLI` is a *library*, and each host compiles a small
  executable — an import, its `AppCtlConfig`, one call — that becomes its own CLI. That executable is macOS-only
  because it shells out to `xcodebuild`, `simctl` and SwiftPM, which is why every file in `AgentCtlCLI` is
  wrapped in `#if os(macOS)`: building the package for an iOS destination compiles that target to nothing
  instead of failing.

## Get started

The whole integration, in five steps — each is a few lines of real code in
[the integration guide](docs/guides/integration.md):

1. **Add the dependency** — `.package(url: "https://github.com/olbartek/agentctl-ios", from: "0.7.0")`, and take only
   the products each target needs (`AgentCtlCore` for screens, `AgentCtlTCA` or `AgentCtlObservation` for the
   config, `AgentCtlCLI` for your CLI, `AgentCtlBridge` for the app shell, `AgentCtlTestSupport` for tests).
2. **Conform your screens** — beside each reducer (or view model), an `AgentScreen` extension: its path, a `key=value` summary, an
   error code and its commands; a container (`AgentContainer`) resolves which screen is active.
3. **Write your CLI** — one `AppCtlConfig` describing your app, and a four-line executable that runs it.
4. **Copy the wrapper** — [`Templates/appctl`](Templates/appctl) rebuilds the CLI quietly before every call.
5. **Run something** — `./appctl screens`, `./appctl run "…"`, `./appctl test`.

## Guides

| Guide | What it covers |
|---|---|
| [Integration](docs/guides/integration.md) | The five steps above in full: screens, commands (`.action`, `.parsing`, `.text`, `.onOff`, `.choice`), gates, containers and inherited commands, mocked clients and `mockCall`, the config, debug-only builds, the wrapper; MVVM-C apps, and moving a host to 0.7. |
| [Commands](docs/guides/commands.md) | Every command your CLI gets (`run`, `test`, `docs`, `check`, `app …`), the exit codes, the runtime commands, and what a headless run pins to stay deterministic. |
| [The device environment](docs/guides/device-environment.md) | `device …`: permissions and system prompts, links, pushes, background, foreground and relaunch, the network, location and biometry — one row per capability, with what your app wires and the real-OS `app` wrapper. |
| [The verification ladder](docs/guides/verification-ladder.md) | `check`, from `swift build` to the real app on a simulator, and verifying at the cheapest rung that proves a change. |
| [Coverage and scenario checks](docs/guides/coverage-and-checks.md) | The guards that fail your build when the agent surface drifts, and the scenario checks every host's tests need. |
| [The in-app bridge](docs/guides/bridge.md) | Driving the real app on a simulator: `AgentLaunch`, launch seeds, `advance` on real time, `app test`. |
| [CONTRACT.md](CONTRACT.md) | The engine specified independently of Swift: what a port implements. |

## The contract

[`CONTRACT.md`](CONTRACT.md) specifies the engine independently of Swift: the script language and its quoting,
command resolution, the three runtime commands, the exact step output format, `expect` semantics and failure
text, the exit codes, the determinism requirements, and the in-app bridge's wire protocol. It is what a port in
another language implements, and it is a more precise description of the behaviour summarized above. Its
examples are TinyApp's, and their output is real.

## The example apps

[`Examples/TinyApp`](Examples/TinyApp) is the smallest complete integration and this package's fixture: two screens,
one mocked client, three scenarios, its own `tinyctl` executable and a committed
[generated command reference](Examples/TinyApp/agent-commands.md). See
[its README](Examples/TinyApp/README.md), or just run it:

```bash
swift run tinyctl run "open 2; save; advance 3s"
swift run tinyctl test
swift test          # this package's own suite, driven against TinyApp
```

[`Examples/TinyMVVM`](Examples/TinyMVVM) is TinyApp rebuilt as MVVM-C, with no TCA. It runs TinyApp's scenario files
unchanged and prints the same output byte for byte (`swift run tinymvvmctl test`). See [its README](Examples/TinyMVVM/README.md).

[`Examples/AgentShop`](Examples/AgentShop) is the showcase: a real iOS app (sign-in, onboarding, a shop with a
cart and checkout) with an Xcode project, 105 scenarios, UI tests generated from them, and the benchmark behind
[the numbers above](#how-much-faster). It is its own package, depending on this one by path. See
[its README](Examples/AgentShop/README.md).

## Status

Version 0.7.0: the engine drives any architecture — a TCA store through `AgentStoreDriver`, or `@Observable` view
models under a coordinator (MVVM-C) through `AgentObservationDriver` — on top of 0.6's
[device environment](docs/guides/device-environment.md) and 0.5, which was extracted from the app it was built for.
The three example apps in this repository are the integrations CI exercises, and the API may still change between
minor versions before 1.0; [moving a host to 0.7](docs/guides/integration.md#moving-a-tca-host-to-07) is a few type
names. MIT licensed.

[agentctl-android](https://github.com/olbartek/agentctl-android) is the Kotlin port of this package. The two move in
lockstep: the same features, the same example apps with the same scenario files, and the same MAJOR.MINOR version,
so 0.7.x here and 0.7.x there implement the same [`CONTRACT.md`](CONTRACT.md). A patch release is one repository's
own fix, so the two patch numbers can differ.
