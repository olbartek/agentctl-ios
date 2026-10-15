# The in-app bridge

`AgentCtlBridge` is `#if DEBUG` from end to end, so a Release build compiles it away, and its server listens on
`127.0.0.1` only. Your app shell therefore uses it inside `#if DEBUG` too — importing it or naming `AgentLaunch`
outside one breaks your Release build. Everything below is the shell's whole integration: in DEBUG it builds the
root view from `launch.store`, calls `await launch.start()` once from that view's `.task`, and shows a
placeholder while `launch.isReady` is false, which is how a launch seed is applied before the first real frame.

```swift
import ComposableArchitecture
import SwiftUI

#if DEBUG
  import AgentCtlBridge
  import MyAppCtl   // the target that holds MyAppConfig
#endif

@main
struct MyApp: App {
  #if DEBUG
    @State private var launch = AgentLaunch(config: MyAppConfig.appCtl)
  #else
    let store = Store(initialState: MyRoot.State()) { MyRoot() }
  #endif

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        Group {
          if launch.isReady {
            RootView(store: launch.store)
          } else {
            ProgressView()
          }
        }
        .task { await launch.start() }
      #else
        RootView(store: store)
      #endif
    }
  }
}
```

To run the plain app over its live dependencies unless an agent launched it, check
`AgentLaunch<MyRoot>.isRequested()` before creating the `AgentLaunch`: it is true when the launch arguments hold
`-agent-port`, which the CLI's `app` subcommands always pass and ⌘R from Xcode does not.

A Release build never names `AgentCtlBridge` or the config's target. `AgentLaunch` reads the launch arguments the
CLI's `app` subcommands pass: `-agent-port <n>` (default `BridgeDefaults.port`, 8765; the CLI passes the free port it
picked and records it in `<outputPath>/bridge.json`, CONTRACT.md §8.6), `-appctl-seed "<script>"` (commands applied before the first real frame, so the app opens already in
that state), `-mock-latency <ms>` and `-clear-session`. `start()` applies the seed before it starts listening, so
the bridge's first answer means the app is ready. A seed is a script and fails like one — at its first failing
step, or at a `(launch)` that did not settle — and the app logs `AgentCtlBridge: seed applied` or
`AgentCtlBridge: seed FAILED (exit <code>)` with its steps.

The same scripts then run against the real app (`app run`), on real time and with real mock latency. `advance`
works there too: the app's `\.continuousClock` is an `AdvanceableClock`, which `advance` moves forward deadline by
deadline, so a countdown ticks once per second advanced, as it does headlessly, and `\.date` moves with it. Only
what sleeps on that clock moves; a timer on `Task.sleep` or a dispatch queue keeps real time. A backend of yours
that reads the time should read `LiveEnvironment.now` (in `makeLive`'s `configure`), as it would read the
`TestClock` headlessly.

`app test` runs the scenario files this way, as `test` runs them headlessly: it builds once, then for each file
launches the app with no saved session and sends the file through the bridge. `--latency <ms>` fixes the mock
latency, `--no-build` uses the installed app, `--record <mp4>` records the simulator for the whole run and writes
`<mp4>.chapters.txt` with the time each scenario started, and `--step-delay <s>` sends one line at a time so the
video can be followed. A few scenarios are true headlessly but not in a running app: a first `expect` on the
launch's own calls (`app launch` has made them before the script starts), a countdown's exact value (it also
ticks in real time), or a date that is in the future only against the headless fixed date. Such a file says so on
a comment line, and `app test` prints it as skipped:

```
# app-test: skip the countdown also ticks in real time
```

If your app opens URLs, stub `openURL` in `makeLive`'s `configure`: opening Safari puts the app, and its bridge,
in the background, and the next request never gets an answer.

The wire protocol — routes, the `X-Appctl-Exit` header, the JSON form, the
launch arguments — is [CONTRACT.md §8](../../CONTRACT.md#8-the-in-app-bridge).
