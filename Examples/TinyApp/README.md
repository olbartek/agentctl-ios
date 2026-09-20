# TinyApp

The worked example for [AgentCtl](../../README.md), and the fixture the package's own tests run against: a list,
a detail screen with a cooldown, and one mocked client. It is small enough to read in one sitting and complete
enough that everything the package offers a host app is visible somewhere in it.

TinyApp is a target of this package rather than a nested package, because the tests
[drive it](../../Tests/AgentCtlTests) and a nested package depending on this one would be a dependency cycle.
Neither it nor `tinyctl` is a product, so nothing you build against AgentCtl builds them.

## Run it

```bash
swift run tinyctl run "open 2; save"          # one step per command
swift run tinyctl run "open 2; save; advance 3s"   # let the cooldown run out
swift run tinyctl run --diff "open 2"         # with a state diff per step
swift run tinyctl test                        # the three scenarios below
swift run tinyctl screens                     # every screen, command and summary key
swift run tinyctl state                       # the full root state
swift run tinyctl docs                        # regenerate agent-commands.md (--check verifies it)
swift run tinyctl --help
```

```
$ swift run tinyctl test
PASS browse (10 steps, 15 ms)
PASS refresh-error (7 steps, 6 ms)
PASS save-cooldown (13 steps, 20 ms)
3 passed, 0 failed
```

(The step counts are fixed — scenario output is deterministic — the millisecond timings are not.)

TinyApp has no Xcode project and no app bundle, so `tinyctl app …`, `tinyctl snapshots` and `tinyctl check` have
nothing to build and cannot work here; `Config.swift` says so where their settings would go. Everything else —
`run`, `state`, `screens`, `docs`, `test` — needs none of them.

## What each file demonstrates

| File | What to look at |
|---|---|
| [`Sources/TinyApp/Items.swift`](Sources/TinyApp/Items.swift) | An ordinary TCA reducer, untouched by AgentCtl. A failed load keeps its rows; `openTapped` for an id the list lacks sets an error instead of doing nothing, so a step never reports silent success. |
| [`Sources/TinyApp/Items+Agent.swift`](Sources/TinyApp/Items+Agent.swift) | The agent surface: paths, `summaryKeys` and `summary`, `errorCode`, `onAppear` (there is no view to send it headlessly), and commands — including a `.parsing` command with an argument and two `gate:`s, which mirror a disabled button. |
| [`Sources/TinyApp/ItemDetail.swift`](Sources/TinyApp/ItemDetail.swift) | The cooldown: an effect suspended on `@Dependency(\.continuousClock)`, which a step reports as `pending=1` and `advance 3s` releases at once. |
| [`Sources/TinyApp/ItemDetail+Agent.swift`](Sources/TinyApp/ItemDetail+Agent.swift) | The smallest useful conformance (about fifteen lines), with a path that carries the item's id — which is how `expect screen=items/2` tells one pushed screen from another. |
| [`Sources/TinyApp/TinyRoot.swift`](Sources/TinyApp/TinyRoot.swift) | The root reducer AgentCtl is generic over: the list plus a `StackState` of pushed screens. |
| [`Sources/TinyApp/TinyRoot+Agent.swift`](Sources/TinyApp/TinyRoot+Agent.swift) | `AgentContainer`: resolving the active screen, lifting its commands (stack element id included), adding `back`, and the `registry` the docs are rendered from. |
| [`Sources/TinyApp/ItemsClient.swift`](Sources/TinyApp/ItemsClient.swift) | A `@DependencyClient` whose mock goes through `mockCall`, which is what makes `calls=items.fetch` appear in a step and `mock items.fetch network` able to fail it. Note that `mockMethods` lists only the codes the *client* can throw, so `mock items.fetch notFound` is rightly rejected. |
| [`Sources/TinyApp/Config.swift`](Sources/TinyApp/Config.swift) | The whole integration: one `AppCtlConfig`, the docs prose, and the deterministic headless and live hosts. |
| [`Sources/tinyctl/main.swift`](Sources/tinyctl/main.swift) | The host's executable — an import, the config, one call. |

## The scenarios

Executable specifications, run by `swift run tinyctl test` and again by the package's
[`ScenarioTests`](../../Tests/AgentCtlTests/ScenarioTests.swift):

| File | What it pins down |
|---|---|
| [`scenarios/browse.appctl`](scenarios/browse.appctl) | The happy path: the list loads on appearance, an item opens, a save starts the cooldown, `advance` runs it out, `back` returns. |
| [`scenarios/refresh-error.appctl`](scenarios/refresh-error.appctl) | A forced failure: `mock` makes the next fetch throw, the rows already loaded stay, and the one-shot fault lets the gated `retry` succeed. |
| [`scenarios/save-cooldown.appctl`](scenarios/save-cooldown.appctl) | The cooldown in detail: a second save is refused with `error=cooldown`, the countdown keeps running, and `advance` releases it a second at a time. |

## The generated command reference

[`agent-commands.md`](agent-commands.md) is written by `swift run tinyctl docs` from the `+Agent.swift` files —
every screen, every command, every summary key, and the mockable methods. It is committed, and
`swift run tinyctl docs --check` (part of this repository's CI) fails when it goes stale, which is what keeps a
generated document worth reading. Never edit it by hand.
