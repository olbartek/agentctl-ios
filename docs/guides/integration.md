# The five-minute integration

Every snippet below is real code from [`Examples/TinyApp`](../../Examples/TinyApp), a two-screen app with one mocked
client that is also this package's test fixture.

## 1. Add the dependency

```swift
dependencies: [
  .package(url: "https://github.com/olbartek/agentctl-ios", from: "0.9.0"),
],
```

Until 1.0, a minor version may change the API (see [Status](../../README.md#status)); `from: "0.9.0"` admits every later
`0.x` release, and your `Package.resolved` holds the exact one.

The package identity is `agentctl-ios`. Take only the products each target needs:

| Product | Who depends on it | What for |
|---|---|---|
| `AgentCtlCore` | the targets holding your screens | `AgentScreen`, `AgentCommand`, `SummaryItem`, `mockCall`, `AgentViewModel` — no TCA |
| `AgentCtlTCA` | the target holding your config, in a TCA app | `AgentStoreDriver`, and the TCA hosts: `HeadlessHost(initialState:reducer:…)` |
| `AgentCtlObservation` | the target holding your config, in an MVVM-C app | `AgentObservationDriver`, and its hosts (see [MVVM-C](#mvvm-c-apps-without-tca)) — no TCA |
| `AgentCtlRuntime` | rarely directly: both adapters re-export it | `AgentDriver`, `AppCtlConfig`, `ScriptRunner`, the deterministic headless host |
| `AgentCtlCLI` | your CLI's executable target | `AgentCtl.run(config:)` (macOS-only) |
| `AgentCtlBridge` | your app shell, and a UI-test target that launches the app | `AgentLaunch`, the DEBUG-only in-app server; `AgentLaunchArguments` |
| `AgentCtlTestSupport` | your test target | the coverage guards and scenario checks |

```swift
.target(
  name: "MyFeature",
  dependencies: [.product(name: "AgentCtlCore", package: "agentctl-ios")]
),
```

## 2. Conform one screen

Beside the reducer, in `<Screen>+Agent.swift`. This is a complete file — the entire agent surface of TinyApp's
detail screen ([`ItemDetail+Agent.swift`](../../Examples/TinyApp/Sources/TinyApp/ItemDetail+Agent.swift), doc comments
trimmed):

```swift
import AgentCtlCore
import ComposableArchitecture

extension ItemDetail: AgentScreen {
  public static let screenPaths = ["items/<id>"]

  public static func screenPath(_ state: State) -> String { "items/\(state.item.id)" }

  public static let summaryKeys = ["title", "saved", "cooldown"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("title", state.item.title),
      SummaryItem("saved", state.saved),
      SummaryItem("cooldown", state.cooldown),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .action(
      "save",
      help: "Save this item. A save starts a \(ItemDetail.cooldownSeconds)-second cooldown; saving again "
        + "before it runs out reports error=cooldown.",
      .saveTapped
    )
  ]
}
```

`screenPaths` is the path as the generated docs list it, with `<id>` standing for the variable part;
`screenPath(_:)` is the concrete one an agent sees and asserts on. `summaryKeys` is checked against what
`summary` actually emits (see [the coverage guards](coverage-and-checks.md#the-coverage-guards)) — and **never put a secret in a
summary**, because it is printed on every step.

A command can do more than send an action. The list screen's
([`Items+Agent.swift`](../../Examples/TinyApp/Sources/TinyApp/Items+Agent.swift)) parse an argument, and are *gated* —
which mirrors a disabled button: the runner refuses the command and names the condition that closed it, instead
of sending an action that could only do nothing.

```swift
  /// Headlessly there is no view to send this, so the runtime sends it when the screen becomes active.
  public static let onAppear: Action? = .onAppear

  public static let commands: [AgentCommand<State, Action>] = [
    .parsing(
      "open",
      argument: "<id>",
      help: "Open an item, e.g. open 2.",
      gate: CommandGate(hint: "items=0") { !$0.items.isEmpty }
    ) { text throws(AgentCommandError) in
      guard let id = Int(text) else { throw .invalidArgument("expected an item id such as 2") }
      return .openTapped(id)
    },
    .action("refresh", help: "Load the list again.", .refresh),
    .action(
      "retry",
      help: "Load the list again after a failure.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retry
    ),
  ]
```

The other command kinds: `.text` takes the rest of the line as it is typed, `.onOff` a switch (`terms on`), and
`.choice` one of a fixed set of words, from which it generates both the documented argument and the error, so the
two cannot drift apart:

```swift
// a String enum, its raw values in allCases order
.choice("tab", of: Tab.self, help: "Switch tab.") { .tabSelected($0) }
// words standing for values
.choice("sort", [("new", Sort.newest), ("cheap", Sort.priceAscending)], help: "Sort.") { .sortTapped($0) }
// the word itself
.choice("login-as", options: ["alice", "bob"], help: "Sign in.") { .loginAs($0) }
```

`tab <shop|cart|orders|profile>` is how the first is documented, and `tab home` fails with
`tab <shop|cart|orders|profile>: invalid argument: expected shop|cart|orders|profile`.

Then a *container* — your navigation stack, tab bar or root reducer — resolves which screen is active, lifts
that screen's commands to its own action type, and appends the commands it owns itself. All of
[`TinyRoot+Agent.swift`](../../Examples/TinyApp/Sources/TinyApp/TinyRoot+Agent.swift):

```swift
extension TinyRoot: AgentContainer {
  static let backHelp = "Go back to the list."

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    guard let id = state.path.ids.last, let top = state.path[id: id] else {
      return Items.activeScreen(state.items).map { .items($0) }
    }
    let child: ActiveScreen<Action> =
      switch top {
      case let .detail(screen):
        ItemDetail.activeScreen(screen).map { .path(.element(id: id, action: .detail($0))) }
      }
    let back = AgentCommand<State, Action>
      .action("back", help: backHelp, .path(.popFrom(id: id)))
      .resolve(state, source: "TinyRoot")
    return child.identified(by: id.debugDescription).appending([back])
  }

  /// Every screen the app can show, for `screens` and the generated docs. Pushed screens inherit `back`.
  public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "TinyRoot")
    return Items.screenDocs + ItemDetail.screenDocs.map { $0.inheriting([back]) }
  }
}
```

Command lookup is **leaf first**: the active screen's own commands, then its containers', then the root's; a
screen can shadow a container's command of the same name.

A container that offers commands on *every* screen beneath it — a root's `login-as`, a tab bar's `tab` — declares
them once as `inheritedCommands`, and `inheritingCommands` adds them both to the active screen and to every screen of
the registry, so the docs cannot list a command the app does not offer. They go after the commands of the screens
beneath, and before the container's own `back`, whichever you apply first; a command with `paths` is offered on
those paths only. A root can also offer a `back` for when nothing is pushed, which fails with
`back: nothing to go back to on <path>` rather than as an unknown command. From AgentShop's
[`AppFeature+Agent.swift`](../../Examples/AgentShop/Sources/AppFeature/AppFeature+Agent.swift):

```swift
extension AppFeature: AgentContainer {
  public static let inheritedCommands: [AgentCommand<State, Action>] = [
    .choice("login-as", [("alice", MockAccounts.alice.user), ("bob", MockAccounts.bob.user)], help: loginAsHelp) {
      .loginAs(MockAccounts.session(for: $0))
    },
    .action("reset", help: resetHelp, .reset),
  ]

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    let screen: ActiveScreen<Action> = …   // the active child, as above
    return inheritingCommands(screen, state).appendingBackFallback(source: containerName)
  }

  public static var registry: [ScreenDoc] {
    let screens = AuthFlow.registry + OnboardingFlow.registry + HomeTabs.registry   // abridged
    return inheritingCommands(screens).map { $0.inheriting([.backFallback(source: containerName)]) }
  }
}
```

Finally, for a call to show up as `calls=items.fetch` — and to be forceable to fail with
`mock items.fetch network` — route your mock through `mockCall`
([`ItemsClient.swift`](../../Examples/TinyApp/Sources/TinyApp/ItemsClient.swift)):

```swift
extension ItemsClient: DependencyKey {
  public static let liveValue = ItemsClient(
    fetch: {
      try await mockCall("items.fetch", error: { ItemsError(rawValue: $0) ?? .network }) { Item.seed }
    }
  )
```

Each client lists the codes `mock` may force on its methods as `MockMethod`s. A failure every call can have,
whatever its client's own errors, is added once rather than per method: `(AuthClient.mockMethods +
OrdersClient.mockMethods).accepting(["network"])` gives each method `network` after its own codes, unless it
already lists it, so `mock`'s `valid:` list and the docs read as if every client had written it out.

## 3. Write your CLI

One type describes your app to AgentCtl: the facts the CLI would otherwise have to hard-code, the prose the
generated command reference is rendered from, and the closures that build your store. Its type names the
*driver* — how the engine reaches your app: `AgentStoreDriver<Root>` for a TCA root reducer. Abridged from
[`Config.swift`](../../Examples/TinyApp/Sources/TinyApp/Config.swift):

```swift
@MainActor
public static var appCtl: AppCtlConfig<AgentStoreDriver<TinyRoot>> {
  AppCtlConfig(
    name: "TinyApp",
    // A real host writes `.workspace("MyApp.xcworkspace", scheme: "MyApp")`, or `.project` for a project.
    target: .project("<none: TinyApp has no Xcode project>", scheme: "TinyApp"),
    // What the CLI walks up the tree for to find the repo root. A host with an Xcode project omits it: its
    // `target`'s path is the marker.
    rootMarker: "Package.swift",
    bundleID: "com.example.TinyApp",
    packages: ["."],         // paths from the root that L0 builds and L1 tests; "." is the package at the root
    simulatorName: "iPhone 17 Pro",
    snapshotRuntimeMajor: 18,
    scenariosPath: "Examples/TinyApp/scenarios",
    docsPath: "Examples/TinyApp/agent-commands.md",
    // The examples every help page prints, in your own vocabulary; TinyApp fills in all seven fields.
    help: HelpExamples(invocation: "swift run tinyctl" /* … */),
    mockMethods: mockMethods,   // what `mock <client.method> <error>` accepts
    docsText: docsText,         // the prose around the generated command reference
    screens: screens,           // TinyRoot.registry
    makeHeadless: { headless() },
    makeLive: { latency in live(latency: latency) },
    clearSession: {}
  )
}

/// A deterministic store on the Mac: a `TestClock`, a fixed date, and everything else `HeadlessHost` pins.
@MainActor
public static func headless() -> HeadlessHost<AgentStoreDriver<TinyRoot>> {
  HeadlessHost(initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, mockMethods: mockMethods) { deps, _ in
    deps.itemsClient = .liveValue
  }
}
```

Your executable is then the whole of
[`Sources/tinyctl/main.swift`](../../Examples/TinyApp/Sources/tinyctl/main.swift):

```swift
#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCLI
  import TinyApp

  await AgentCtl.run(config: TinyAppConfig.appCtl)
#endif
```

**Debug builds only.** `AgentCtlRuntime`, `AgentCtlTCA`, `AgentCtlObservation`, `AgentCtlCLI` and
`AgentCtlTestSupport` compile to nothing in a release
build, so that none of AgentCtl's runtime ships in your app: SwiftPM cannot leave a dependency out of one build
configuration, so the code leaves itself out. Wrap the target that holds your config in the same condition
(`#if DEBUG || AGENTCTL_RELEASE` around each file, as TinyApp's `Config.swift` is), and your features' `+Agent.swift`
files, which only use `AgentCtlCore`, need nothing. Your CLI builds in debug; to build it in release, pass
`-Xswiftc -DAGENTCTL_RELEASE`, which [the wrapper](#4-copy-the-wrapper) does when you set its configuration to
`release`.

Declare it in your package next to the target that holds the config. (TinyApp lives inside *this* package, so it
names `"AgentCtlCLI"` as a plain target; your package writes
`.product(name: "AgentCtlCLI", package: "agentctl-ios")`.)

```swift
.executableTarget(
  name: "tinyctl",
  dependencies: ["TinyApp", "AgentCtlCLI"],
  path: "Examples/TinyApp/Sources/tinyctl"
),
```

Every help page, every error message and the generated document now name *your* CLI and *your* app:

```
$ swift run tinyctl --help
OVERVIEW: Drive TinyApp headlessly, run its scenarios and check the
verification ladder.

TinyApp is this repository's example app; it runs headlessly, with no
simulator.
Command reference: Examples/TinyApp/agent-commands.md (or swift run tinyctl
screens).

USAGE: tinyctl <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  run                     Run a script against a fresh headless app and print
                          one step per command.
  state                   Print the full root state (customDump) after
                          replaying an optional session file.
  screens                 List every screen path with its commands, arguments
                          and help, including inherited commands.
  docs                    Write Examples/TinyApp/agent-commands.md from the
                          command registry.
  test                    Run scenario files (default:
                          Examples/TinyApp/scenarios/*.appctl) and print
                          pass/fail per file.
  snapshots               Run the L3 view snapshot tests on an iOS 18 simulator
                          (or re-record the reference images).
  check                   Run the verification ladder: L0 build, L1 tests, L2
                          scenarios, docs check (--ui adds L3 and L4).
  app                     Launch the app on a simulator and drive it through
                          its agent bridge.

  See 'tinyctl help <subcommand>' for detailed help.
```

## 4. Copy the wrapper

Agents should never call `swift run`: it prints its build log to stdout, mixed into the step output they are
supposed to read. [`Templates/appctl`](../../Templates/appctl) rebuilds your executable incrementally (about half a
second when nothing changed), sends the build log to stderr, exits 3 if the build fails, and then `exec`s the
binary. SwiftPM's incremental build can trip over its own cache when a pull or a branch switch adds or removes a
source file of a path dependency ("because of missing inputs", "unable to load output file map", or a new file
simply not compiled). So a failed build is planned afresh once: the build plan and any stale target's build
directory are removed and the build runs again, in seconds. If that works, stderr says `appctl: the build cache was
stale (a pull or a branch switch?); planned the build afresh and it succeeded`. Stale-cache errors that persist get
two more rounds, then one full `swift package clean`, which rebuilds every dependency; a genuine compile error costs
one quick extra build and exits 3, its errors shown once:

```bash
cp Templates/appctl ./appctl     # then set PACKAGE and PRODUCT at the top of the file
chmod +x ./appctl
./appctl run "open 2; save"
```

Name the file whatever your agents should type, and give `HelpExamples.invocation` the same spelling, so the
help pages name a command that exists in your repo. The wrapper also exports `APPCTL_ROOT`, which is what
`scenariosPath` and `docsPath` are resolved against; without it the CLI walks up from the working directory
looking for the config's `rootMarker` (by default its `.xcworkspace` or `.xcodeproj`).

The example in *this* repository has no wrapper: it is a target of this package, so `swift run tinyctl …` is its
invocation, and that is what its help and its docs say.

## 5. Run something

```
$ swift run tinyctl screens
items  [Items]
  open <id>               Open an item, e.g. open 2. [disabled when items=0]
  refresh                 Load the list again.
  retry                   Load the list again after a failure. [disabled when error=none]
  summary: items loading
items/<id>  [ItemDetail]
  save                    Save this item. A save starts a 3-second cooldown; saving again before it runs out reports error=cooldown.
  back                    Go back to the list.  (TinyRoot)
  summary: title saved cooldown
```

(The real listing ends with a third block, `every screen [runtime]`, holding the runtime commands below, and the
`device` subcommands TinyApp enables: `device open-url <url>` and `device push <name> [tap]`.)

Force a client failure, watch the screen report it, then recover — the fault is one-shot:

```
$ swift run tinyctl run "mock items.fetch network; refresh; expect error=network items=3"
> (launch)
  screen=items items=3 loading=false calls=items.fetch
> mock items.fetch network
  screen=items items=3 loading=false
> refresh
  screen=items items=3 loading=false calls=items.fetch error=network
> expect error=network items=3
  screen=items items=3 loading=false calls=items.fetch error=network
```

A failed `expect` still prints the state, says which pair was unmet, and exits 1:

```
$ swift run tinyctl run "open 2; expect saved=true"; echo "exit=$?"
> (launch)
  screen=items items=3 loading=false calls=items.fetch
> open 2
  screen=items/2 title="Second item" saved=false cooldown=0
> expect saved=true
  screen=items/2 title="Second item" saved=false cooldown=0
  FAIL expected saved=true, got saved=false
exit=1
```

A command that does not exist here is answered with the ones that do:

```
$ swift run tinyctl run "frobnicate"; echo "exit=$?"
> (launch)
  screen=items items=3 loading=false calls=items.fetch
> frobnicate
  screen=items items=3 loading=false
  FAIL unknown command 'frobnicate' on items. Valid here: open <id>, refresh, retry, expect, advance, mock, device
exit=1
```

…and a gated one names the condition that closed it:

```
$ swift run tinyctl run "retry"; echo "exit=$?"
> (launch)
  screen=items items=3 loading=false calls=items.fetch
> retry
  screen=items items=3 loading=false
  FAIL retry is disabled here (error=none)
exit=1
```

## MVVM-C apps, without TCA

The engine never sees your app's types: it talks to an `AgentDriver`, which answers five questions — which screen is
active, deliver this action, has anything changed (settling's fingerprint), relaunch, and dump the state. TCA apps use
`AgentStoreDriver`; an app of `@Observable` view models under a coordinator uses `AgentObservationDriver` from
`AgentCtlObservation`. Scripts, scenarios, the step output and the generated docs are the same either way:
[`Examples/TinyMVVM`](../../Examples/TinyMVVM) is TinyApp rebuilt as MVVM-C, and it runs TinyApp's scenario files
byte for byte.

A screen is an `AgentViewModel`. Its agent surface is the `AgentScreen` you already know, computed from a value,
`agentState`; its commands are `AgentScreenIntent`s, closures over the view model on screen:

```swift
extension ItemsViewModel: AgentViewModel {
  public struct AgentState: Equatable, Sendable {
    var items: Int
    var isLoading: Bool
    var error: ItemsError?
  }

  public var agentState: AgentState { AgentState(items: items.count, isLoading: isLoading, error: error) }

  nonisolated public static let screenPaths = ["items"]
  nonisolated public static func screenPath(_ state: AgentState) -> String { "items" }
  // summaryKeys, summary(_:), errorCode(_:) exactly as for a TCA screen
  nonisolated public static var onAppear: AgentScreenIntent<ItemsViewModel>? { AgentScreenIntent { $0.onAppear() } }

  nonisolated public static var commands: [AgentCommand<AgentState, AgentScreenIntent<ItemsViewModel>>] {
    [.action("refresh", help: "Load the list again.", AgentScreenIntent { $0.refresh() })]
  }
}
```

The coordinator is an `AgentCoordinator`: it returns the screen on top (`items.activeScreen()`, or a pushed view
model's, with its own `back` appended as an `AgentIntent`), its `registry`, and `cancelAllWork()`. The config names
`AgentObservationDriver<AppCoordinator>`, and its hosts take the coordinator to build:

```swift
public static func headless() -> HeadlessHost<AgentObservationDriver<AppCoordinator>> {
  HeadlessHost(mockMethods: mockMethods, device: device) { deps, _ in
    deps.itemsClient = .liveValue
  } coordinator: {
    AppCoordinator()
  }
}
```

A store keeps a reducer deterministic for free; a view model keeps itself deterministic by following these rules,
and settling relies on every one of them:

- **View models are `@MainActor`**, and the coordinator creates them; nothing builds one on another actor.
- **Every clock, date, UUID and client comes from `@Dependency`** (swift-dependencies), never `Date()`, `Task.sleep`
  or a singleton. The headless host pins them as it does for TCA.
- **Async work starts through `AgentTasks`**: `tasks.run(for: self) { … }` with `@Dependency(\.agentTasks)`.
  That is how settling knows work is in flight (`pending=` in a step); a bare `Task { }` is invisible to it.
- **A child is created inside its parent's dependencies**: `withDependencies(from: self) { DetailViewModel(…) }`.
- **A pop cancels the popped screen's work**, as TCA cancels a stack element's effects: the coordinator calls the
  view model's `cancelAllWork()`.
- **Stack ids are a counter, not `UUID()`**: they appear in screen identity (`#3`), which must be the same every run.
- **Appearing is an intent**: the screen's `onAppear` is what the runner sends headlessly, and what the view's
  `.onAppear` calls in the app.

In the app shell, `AgentLaunch(config:)` works as it does for TCA; `launch.app` is the coordinator, and a
`device relaunch` replaces it (see [the bridge guide](bridge.md)).

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

### Moving a TCA host to 0.7

0.7 put the engine behind `AgentDriver`. A TCA host changes a few type names and nothing else:

- `AppCtlConfig<Root>`, `HeadlessHost<Root>`, `LiveHost<Root>` and `ScriptRunner<Root>` become
  `…<AgentStoreDriver<Root>>`. The `HeadlessHost(initialState:reducer:…)` and `LiveHost(…)` initializers are unchanged.
- The same for the test helpers that name the root: `AgentCoverage<AgentStoreDriver<Root>>` and
  `AgentScenarioChecks<AgentStoreDriver<Root>>`. Test files that build a host import `AgentCtlTCA`.
- `AgentLaunch.store` is now `launch.app` (`store` still compiles, with a deprecation warning), and
  `AgentLaunch<Root>.isRequested()` is `AgentLaunchArguments.isRequested()`.
