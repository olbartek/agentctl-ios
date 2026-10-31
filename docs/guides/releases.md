# Releases

Every version, newest first: what changed, and what a host changes to move to it.

## 0.11.0 (2026-10-31)

A UIKit app, or any app on iOS 16, starts the debug bridge in one line: `AgentLaunchSession` does everything `AgentLaunch` does, without `@Observable`. Released with agentctl-android 0.11.0; CONTRACT.md is unchanged (version 4). [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.11.0).

### Moving a host to 0.11

0.11 adds `AgentLaunchSession`: everything `AgentLaunch` does — the token gate, `-clear-session`, the live host, the
launch seed and the bridge — without `@Observable`, so a UIKit app, or any app on iOS 16, starts the bridge with it
instead of building one from `BridgeServer` (see [the bridge guide](bridge.md#uikit-apps-and-ios-16)). Nothing else
changes; scripts, scenarios, the CLI and CONTRACT.md (still version 4) are the same.

- **A SwiftUI app keeps `AgentLaunch`**, with the same API. It now wraps a session, which `launch.session` exposes.
- **`AgentLaunch.Options` is `AgentLaunchOptions`**, a type of its own, as on Android. The old name is an alias.
- **On Android the names differ**: its `AgentLaunch` plays this `AgentLaunchSession`'s role, and its `AgentLaunchSession`
  is a lower-level JVM piece. [Differences from agentctl-android](platform-differences.md) maps them.
- **A host that started the bridge itself** — `BridgeServer` and `BridgeRouter` with its own argument parsing — moves
  to `AgentLaunchSession` and deletes that code.

## 0.10.0 (2026-10-31)

The libraries support iOS 16, down from iOS 18, and an iOS 16 build checks that the floor holds. TinyMVVM became a package of its own. Released with agentctl-android 0.10.0; CONTRACT.md is unchanged (version 4). [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.10.0).

### Moving a host to 0.10

0.10 lowers the libraries' floor from iOS 18 to iOS 16. Nothing changes for a host on iOS 18: scripts, scenarios,
the CLI and CONTRACT.md (still version 4) are the same.

- **A host on iOS 16 or 17** can now depend on every product. `AgentLaunch` is `@Observable`, so it is
  `@available(iOS 17, *)`: an app whose floor is iOS 16 uses it only where `#available(iOS 17, *)` holds.
- **TinyMVVM is its own package** (`Examples/TinyMVVM`), like AgentShop, because Swift's `@Observable` needs iOS 17.
  Run its CLI from its directory: `cd Examples/TinyMVVM && swift run tinymvvmctl test`.

## 0.9.1 (2026-10-16)

An iOS-only patch: the bridge's token helpers no longer ship in a Release build. Nothing changes in a Debug build, the CLI or CONTRACT.md. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.9.1).

## 0.9.0 (2026-10-16)

A locked-down bridge (CONTRACT.md version 4): a fresh token per launch on every request, loopback `Host` and no `Origin`, strict request parsing and a 1 MiB body cap. Released with agentctl-android 0.9.0. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.9.0).

### Moving a host to 0.9

0.9 hardens the in-app bridge (CONTRACT.md version 4, §8): every request carries the token of the launch that started
it, a loopback `Host` and no `Origin`, and the bridge parses requests strictly. The token ties requests to whoever
launched the app; the launch itself is not authenticated, so anything that can launch a debug build can still give it
a token of its own, as before. The Host and Origin checks do not stop every request a web page can make; the token
does. Scripts and scenarios are unchanged; what launches the app may need a line:

- **Gate `AgentLaunch` behind `AgentLaunchArguments.isRequested()`**, as [the bridge guide](bridge.md) shows. It is now
  true only for a well-formed `-agent-token` (32 lowercase hex characters), which every CLI launch passes; `-agent-port`
  alone no longer counts.
- **An `AgentLaunch` started without a token does not listen.** It logs `AgentCtlBridge: no -agent-token; not
  listening` and ignores `-agent-port`, `-appctl-seed`, `-mock-latency` and `-clear-session`: a launch without a token
  neither seeds nor resets the app.
- **UI tests that launch the app themselves pass a token**: add `"-agent-token", AgentLaunchArguments.makeToken()` to
  `launchArguments` beside `-clear-session` or `-appctl-seed`, and link `AgentCtlBridge` to the UI-test target (see
  [UI tests that launch the app themselves](bridge.md#ui-tests-that-launch-the-app-themselves)).
- **The token travels in `bridge.json`.** `app launch` writes it beside the port, with mode 0600, and `app run`,
  `app state` and `app screens` send it to the port the file records. `APPCTL_TOKEN` overrides it, as `APPCTL_PORT`
  does the port. A bridge that refuses it exits 3 with `refused the token (relaunch it: <cli> app launch)`: relaunch
  the app, since a `bridge.json` from before 0.9 has no token. A script or tool that calls the bridge itself sends
  `X-Appctl-Token` and a loopback `Host`, and no `Origin`.

## 0.8.0 (2026-10-16)

Stricter scripts and exit codes (CONTRACT.md version 3), from a full audit of both libraries: CRLF ends a line, `expect` needs an unquoted `=`, and usage and environment failures exit 2 and 3. Released with agentctl-android 0.8.0. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.8.0).

### Moving a host to 0.8

0.8 makes the CLI follow CONTRACT.md version 3 more strictly. Scenarios that passed keep passing, with these
exceptions to check:

- A scenario file with CRLF line endings now runs every line. One that passed before may have run nothing (a CRLF
  file starting with `#` was one long comment), so it can now fail for real.
- `expect "key=value"` with the `=` only inside quotes is a syntax error (exit 2); write `expect key="value"`.
- An argument is unquoted only when it is one quoted span from end to end: `"a"b"c"` stays as written.
- `snapshots` and `check` exit 2 for a usage error and 3 for an environment failure (no simulator, a tool that could
  not start); 1 still means the app was found wrong. A command group run without a subcommand (`appctl`, `appctl app`)
  exits 2, and a `--session` file that cannot be read, or is not UTF-8, exits 3.
- `ScriptRunner.run` is `async throws(CancellationError)`: a host that calls it directly adds `try`. A bridge request
  whose client goes away is cancelled and gets no answer (CONTRACT §8.1).

## 0.7.0 (2026-10-16)

The engine drives any architecture through `AgentDriver`: a TCA store with `AgentStoreDriver`, or view models under a coordinator with `AgentObservationDriver` (MVVM-C, no TCA). Released with agentctl-android 0.7.0; scripts and step output are unchanged. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.7.0).

### Moving a TCA host to 0.7

0.7 put the engine behind `AgentDriver`. A TCA host changes a few type names and nothing else:

- `AppCtlConfig<Root>`, `HeadlessHost<Root>`, `LiveHost<Root>` and `ScriptRunner<Root>` become
  `…<AgentStoreDriver<Root>>`. The `HeadlessHost(initialState:reducer:…)` and `LiveHost(…)` initializers are unchanged.
- The same for the test helpers that name the root: `AgentCoverage<AgentStoreDriver<Root>>` and
  `AgentScenarioChecks<AgentStoreDriver<Root>>`. Test files that build a host import `AgentCtlTCA`.
- `AgentLaunch.store` is now `launch.app` (`store` still compiles, with a deprecation warning), and
  `AgentLaunch<Root>.isRequested()` is `AgentLaunchArguments.isRequested()`.

## 0.6.0 (2026-10-16)

The device environment: the runtime command `device` simulates permissions and system prompts, links, pushes, the app's lifecycle, the network, location and biometry, the same headlessly and in the running app (CONTRACT.md version 2). Released with agentctl-android 0.6.0. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.6.0).

## 0.5.0 (2026-09-30)

Two apps on one Mac without crossed wires: the bridge's port is picked and recorded in `.appctl/bridge.json`, and every response says which app answered. Also device commands for demos, and live settling that waits for the UI. Released with agentctl-android 0.5.0. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.5.0).

## 0.4.1 (2026-09-29)

Lockstep with agentctl-android: the same scenario files on both sides, and a fix to `app test`. [Tag](https://github.com/olbartek/agentctl-ios/tree/0.4.1).

## 0.4.0 (2026-09-24)

Scenarios on a simulator (`app test`), `advance` in the running app, and nothing of AgentCtl in a Release build but the screens' vocabulary. Also the AgentShop showcase and its benchmark. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.4.0).

## 0.3.0 (2026-09-21)

No assumed repository layout: packages are paths from the repo root, and `outputPath` says where the CLI writes. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.3.0).

## 0.2.1 (2026-09-21)

`check`'s report no longer cuts its detail column off. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.2.1).

## 0.2.0 (2026-09-21)

Fixes from a whole-package review, and the first CONTRACT.md that stands on its own as the spec for another platform. Nothing passes that did not run: a `(launch)` that never settles fails, and so does `test` with no scenarios. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.2.0).

## 0.1.1 (2026-09-21)

The package is named `agent-ctl`, as Xcode shows it. No API change. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.1.1).

## 0.1.0 (2026-09-21)

The first release: screens that describe themselves, a script language with `expect`, headless runs on a Mac, and a debug-only in-app bridge. [Release notes](https://github.com/olbartek/agentctl-ios/releases/tag/0.1.0).
