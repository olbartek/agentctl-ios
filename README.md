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

## Get started

The whole integration, in five steps — each is a few lines of real code in
[the integration guide](docs/guides/integration.md):

1. **Add the dependency** — `.package(url: "https://github.com/olbartek/agentctl-ios", from: "0.11.0")`, and take only
   the products each target needs (`AgentCtlCore` for screens, `AgentCtlTCA` or `AgentCtlObservation` for the
   config, `AgentCtlCLI` for your CLI, `AgentCtlBridge` for the app shell, gated behind `AgentLaunchArguments.isRequested()`,
   and for UI tests that launch the app, `AgentCtlTestSupport` for tests).
2. **Conform your screens** — beside each reducer (or view model), an `AgentScreen` extension: its path, a `key=value` summary, an
   error code and its commands; a container (`AgentContainer`) resolves which screen is active.
3. **Write your CLI** — one `AppCtlConfig` describing your app, and a four-line executable that runs it.
4. **Copy the wrapper** — [`Templates/appctl`](Templates/appctl) rebuilds the CLI quietly before every call.
5. **Run something** — `./appctl screens`, `./appctl run "…"`, `./appctl test`.

## Documentation

The [wiki](https://github.com/olbartek/agentctl-ios/wiki) is where to read it all. It is generated from this
repository's [`docs/guides`](docs/guides) by [`scripts/wiki-sync`](scripts/wiki-sync), so the same pages are here, at
every tag:

| Page | What it covers |
|---|---|
| [Overview](docs/guides/overview.md) | How much faster than UI tests, what it needs and is not, the packages, the example apps, building this repository. |
| [Getting started](docs/guides/integration.md) | The five steps above in full: screens, commands (`.action`, `.parsing`, `.text`, `.onOff`, `.choice`), gates, containers and inherited commands, mocked clients and `mockCall`, the config, debug-only builds, the wrapper; MVVM-C apps. |
| [Commands](docs/guides/commands.md) | Every command your CLI gets (`run`, `test`, `docs`, `check`, `app …`), the exit codes, the runtime commands, and what a headless run pins to stay deterministic. |
| [The in-app bridge](docs/guides/bridge.md) | Driving the real app on a simulator: `AgentLaunch` and `AgentLaunchSession`, launch seeds, `advance` on real time, `app test`, the bridge's token, and UI tests that launch the app. |
| [The device environment](docs/guides/device-environment.md) | `device …`: permissions and system prompts, links, pushes, background, foreground and relaunch, the network, location and biometry. |
| [The verification ladder](docs/guides/verification-ladder.md) | `check`, from `swift build` to the real app on a simulator, and verifying at the cheapest rung that proves a change. |
| [Coverage and checks](docs/guides/coverage-and-checks.md) | The guards that fail your build when the agent surface drifts, and the scenario checks every host's tests need. |
| [Platform differences](docs/guides/platform-differences.md) | Which type plays which role here and in [agentctl-android](https://github.com/olbartek/agentctl-android) where the names differ. |
| [The contract](docs/guides/contract.md) | [`CONTRACT.md`](CONTRACT.md), the engine specified independently of Swift: what a port implements. |
| [Releases](docs/guides/releases.md) | Every version, and what a host changes to move to it. |
| [Before 1.0](docs/guides/before-1.0.md) | What may still change, and what is to be settled by 1.0. |

## Status

Version 0.11.0 ([releases](docs/guides/releases.md)). The API may still change between minor versions before 1.0
([before 1.0](docs/guides/before-1.0.md)). MIT licensed.

[agentctl-android](https://github.com/olbartek/agentctl-android) is the Kotlin port of this package. The two move in
lockstep: the same features, the same example apps with the same scenario files, and the same MAJOR.MINOR version,
so 0.11.x here and 0.11.x there implement the same [`CONTRACT.md`](CONTRACT.md). A patch release is one repository's
own fix, so the two patch numbers can differ.
