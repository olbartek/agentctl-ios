# The in-app bridge

`AgentCtlBridge` is `#if DEBUG` from end to end, so a Release build compiles it away, and its server listens on
`127.0.0.1` only. Your app shell therefore uses it inside `#if DEBUG` too — importing it or naming `AgentLaunch`
outside one breaks your Release build. Everything below is the shell's whole integration: in DEBUG, when an agent
launched the app (`AgentLaunchArguments.isRequested()`), it builds the root view from `launch.app` (the store of a TCA
app, the coordinator of an MVVM-C app), calls `await launch.start()` once from that view's `.task`, and shows a
placeholder while `launch.isReady` is false, which is how a launch seed is applied before the first real frame. Any
other launch, ⌘R from Xcode included, is the plain app.

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
    @State private var launch = AgentLaunchArguments.isRequested() ? AgentLaunch(config: MyAppConfig.appCtl) : nil
  #endif
  @State private var store = Store(initialState: MyRoot.State()) { MyRoot() }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let launch {
          Group {
            if launch.isReady {
              RootView(store: launch.app)
            } else {
              ProgressView()
            }
          }
          .task { await launch.start() }
        } else {
          RootView(store: store)
        }
      #else
        RootView(store: store)
      #endif
    }
  }
}
```

`AgentLaunchArguments.isRequested()` is true when the launch arguments hold a well-formed `-agent-token`: 32 lowercase
hex characters, which the CLI's `app` subcommands make afresh for every launch. Without one, an `AgentLaunch` starts no
bridge (it logs `AgentCtlBridge: no -agent-token; not listening`) and ignores every other launch argument below, so an
`AgentLaunch` created anyway is harmless, but it is not the plain app either: checking first keeps ⌘R on your live
dependencies.

A Release build never names `AgentCtlBridge` or the config's target. `AgentLaunch` reads the launch arguments the
CLI's `app` subcommands pass: `-agent-token <t>` (the launch's token), `-agent-port <n>` (default `BridgeDefaults.port`, 8765; the CLI passes the free port it
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

`wait` blocks until the app gets somewhere, so a client never polls `GET /snapshot`: `app run 'wait 30s
screen=chat/voice'` returns as soon as the app has settled on that screen, and a bare `app run 'wait 30s'` as soon
as it has settled on any change to the screen's line (path, summary, error or prompt), from the state the previous
step settled on. Either fails with exit 1 and the screen as it stands once the time runs out. A driver that cannot
name the next state loops: act, `wait`, read the step, decide. Requests are answered one at a time, so a waiting
`POST /run` holds the ones behind it; closing its connection ends the wait.

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

## UIKit apps and iOS 16

`AgentLaunch` is `@Observable` for the SwiftUI view above, which is why it needs iOS 17. `AgentLaunchSession` is the
same launch without it: the same launch arguments, the same seed and the same bridge, from iOS 16 and with no UI
framework. It tells you about its two changes through closures instead: `onReady` when the seed is applied, and
`onAppChange` with the new app after a `device relaunch`. A UIKit app keeps one in its scene delegate:

```swift
#if DEBUG
  import AgentCtlBridge
  import MyAppCtl
#endif

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  #if DEBUG
    private var session: AgentLaunchSession<AgentObservationDriver<AppCoordinator>>?
  #endif

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    self.window = window
    #if DEBUG
      if AgentLaunchArguments.isRequested() {
        let launch = AgentLaunchSession(config: MyAppConfig.appCtl)
        self.session = launch
        launch.onAppChange = { [weak self] coordinator in self?.show(coordinator) }
        launch.onReady = { [weak self, weak launch] in if let launch { self?.show(launch.app) } }
        if launch.isReady { show(launch.app) } else { window.rootViewController = SplashViewController() }
        window.makeKeyAndVisible()
        Task { await launch.start() }
        return
      }
    #endif
    show(AppCoordinator())
    window.makeKeyAndVisible()
  }

  private func show(_ coordinator: AppCoordinator) {
    window?.rootViewController = coordinator.rootViewController
  }
}
```

Call `start()` once, after the first screen is up: it applies the seed before it starts listening, exactly as
`AgentLaunch.start()` does, and without a token it logs `AgentCtlBridge: no -agent-token; not listening` and returns.
Keep the session for the life of the app; the bridge stops with it.

## Who may use the bridge

Every request carries the launch's token in `X-Appctl-Token`, and a `Host` of `127.0.0.1` or `localhost`; one with an
`Origin` header is refused. The bridge answers `403 forbidden` or `401 unauthorized` (exit 3) without reading the
request's body, rejects ambiguous framing (`Transfer-Encoding`, a repeated `Content-Length`) and caps a body at 1 MiB.
The CLI finds the token where it finds the port: `<outputPath>/bridge.json` (written with mode 0600) for the port it
records, or `APPCTL_TOKEN`, which overrides the file as `APPCTL_PORT` does. A bridge that refuses the token says so
(`refused the token (relaunch it: <cli> app launch)`): the app was launched again since, or by someone else.

What this does and does not cover, in a debug build: the token ties requests to whoever launched the app, but the
launch itself is not authenticated, so anything that can launch a debug build can give it a token of its own (as
before 0.9). The Host and Origin checks turn away most requests a web page could make, but not all of them; what stops
the rest is the token, which a web page does not have.

To talk to the bridge yourself (`curl`), send what the CLI sends:

```
curl -H "X-Appctl-Token: $(jq -r .token .appctl/bridge.json)" http://127.0.0.1:8765/snapshot
```

## UI tests that launch the app themselves

An XCUITest that launches the app with `-clear-session`, `-appctl-seed` or `-mock-latency` passes a fresh token beside
them, or the app ignores them. `AgentLaunchArguments.makeToken()` makes one; link `AgentCtlBridge` to the UI-test
target (it is the module `AgentLaunchArguments` lives in, built anyway for the app, and the UI-test runner is a process
of its own, so nothing is linked twice into one process):

```swift
import AgentCtlBridge
import XCTest

let app = XCUIApplication()
app.launchArguments = ["-agent-token", AgentLaunchArguments.makeToken(), "-clear-session", "-mock-latency", "0", "-agent-port", "0"]
app.launch()
```

AgentShop's generated UI tests launch this way (`Examples/AgentShop/App/AgentShopUITests/ShopUITestCase.swift`).
`-agent-port 0` lets the app's bridge take any free port, so a UI test never clashes with another copy of the app.

The wire protocol — routes, headers, the token, the JSON form, the
launch arguments — is [CONTRACT.md §8](../../CONTRACT.md#8-the-in-app-bridge).
