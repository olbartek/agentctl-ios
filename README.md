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
[this video](docs/benchmarks/2026-09-24-agentshop.mp4) runs three scenarios side by side.

The modes check different things, so this is not a case for deleting UI tests: the generated UI tests found a
place where the headless run disagreed with iOS. It is a case for which one an agent runs hundreds of times a day.

## Requirements, and what this is not

- **macOS 15+ and a Swift 6.1+ toolchain** (`swift-tools-version: 6.1`; developed and verified on Swift 6.3,
  Xcode 26.6). The library targets support iOS 18+ as well; the CLI is macOS-only, see below.
- **The app must be built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)**
  (1.26+) today. `AgentCtlCore` — the vocabulary, the script parser, `expect`, the step format, the mock call
  log — deliberately has no TCA dependency, so supporting another architecture means writing a second runner
  against the same vocabulary rather than rewriting it. That runner does not exist yet.
- **Screens are driven through state, not through the UI.** Nothing taps and nothing reads pixels; a headless
  run has no views at all. Rendering is verified separately, by snapshot tests (see
  [the ladder](#the-verification-ladder)).
- **The CLI cannot ship as a prebuilt binary.** It links your reducers: it builds your app's store in its own
  process and sends your actions to it. So `AgentCtlCLI` is a *library*, and each host compiles a small
  executable — an import, its `AppCtlConfig`, one call — that becomes its own CLI. That executable is macOS-only
  because it shells out to `xcodebuild`, `simctl` and SwiftPM, which is why every file in `AgentCtlCLI` is
  wrapped in `#if os(macOS)`: building the package for an iOS destination compiles that target to nothing
  instead of failing.

## The five-minute integration

Every snippet below is real code from [`Examples/TinyApp`](Examples/TinyApp), a two-screen app with one mocked
client that is also this package's test fixture.

### 1. Add the dependency

```swift
dependencies: [
  .package(url: "https://github.com/olbartek/agentctl-ios", from: "0.3.0"),
],
```

Until 1.0, a minor version may change the API (see [Status](#status)); `from: "0.3.0"` admits every later
`0.x` release, and your `Package.resolved` holds the exact one.

The package identity is `agentctl-ios`, and it exposes five products. Take only what each target needs:

| Product | Who depends on it | What for |
|---|---|---|
| `AgentCtlCore` | the targets holding your screens | `AgentScreen`, `AgentCommand`, `SummaryItem`, `mockCall` — no TCA |
| `AgentCtlTCA` | the target holding your config | `AppCtlConfig`, `ScriptRunner`, the deterministic headless host |
| `AgentCtlCLI` | your CLI's executable target | `AgentCtl.run(config:)` (macOS-only) |
| `AgentCtlBridge` | your app shell | `AgentLaunch`, the DEBUG-only in-app server |
| `AgentCtlTestSupport` | your test target | the coverage guards |

```swift
.target(
  name: "MyFeature",
  dependencies: [.product(name: "AgentCtlCore", package: "agentctl-ios")]
),
```

### 2. Conform one screen

Beside the reducer, in `<Screen>+Agent.swift`. This is a complete file — the entire agent surface of TinyApp's
detail screen ([`ItemDetail+Agent.swift`](Examples/TinyApp/Sources/TinyApp/ItemDetail+Agent.swift), doc comments
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
`summary` actually emits (see [the coverage guards](#the-coverage-guards)) — and **never put a secret in a
summary**, because it is printed on every step.

A command can do more than send an action. The list screen's
([`Items+Agent.swift`](Examples/TinyApp/Sources/TinyApp/Items+Agent.swift)) parse an argument, and are *gated* —
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

Then a *container* — your navigation stack, tab bar or root reducer — resolves which screen is active, lifts
that screen's commands to its own action type, and appends the commands it owns itself. All of
[`TinyRoot+Agent.swift`](Examples/TinyApp/Sources/TinyApp/TinyRoot+Agent.swift):

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

Finally, for a call to show up as `calls=items.fetch` — and to be forceable to fail with
`mock items.fetch network` — route your mock through `mockCall`
([`ItemsClient.swift`](Examples/TinyApp/Sources/TinyApp/ItemsClient.swift)):

```swift
extension ItemsClient: DependencyKey {
  public static let liveValue = ItemsClient(
    fetch: {
      try await mockCall("items.fetch", error: { ItemsError(rawValue: $0) ?? .network }) { Item.seed }
    }
  )
```

### 3. Write your CLI

One type describes your app to AgentCtl: the facts the CLI would otherwise have to hard-code, the prose the
generated command reference is rendered from, and the closures that build your store. Abridged from
[`Config.swift`](Examples/TinyApp/Sources/TinyApp/Config.swift):

```swift
@MainActor
public static var appCtl: AppCtlConfig<TinyRoot> {
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
public static func headless() -> HeadlessHost<TinyRoot> {
  HeadlessHost(initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, mockMethods: mockMethods) { deps, _ in
    deps.itemsClient = .liveValue
  }
}
```

Your executable is then the whole of
[`Sources/tinyctl/main.swift`](Examples/TinyApp/Sources/tinyctl/main.swift):

```swift
#if os(macOS)
  import AgentCtlCLI
  import TinyApp

  await AgentCtl.run(config: TinyAppConfig.appCtl)
#endif
```

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

### 4. Copy the wrapper

Agents should never call `swift run`: it prints its build log to stdout, mixed into the step output they are
supposed to read. [`Templates/appctl`](Templates/appctl) rebuilds your executable incrementally (about half a
second when nothing changed), sends the build log to stderr, exits 3 if the build fails, and then `exec`s the
binary:

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

### 5. Run something

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

(The real listing ends with a third block, `every screen [runtime]`, holding the three runtime commands below.)

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
  FAIL unknown command 'frobnicate' on items. Valid here: open <id>, refresh, retry, expect, advance, mock
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

## The commands your CLI gets

| Command | What it does |
|---|---|
| `run "<script>"` | Run a script against a fresh headless app, one step per command. `--diff` adds a state diff per step, `--json` prints a JSON array of steps instead of text, and `--session <file>` replays a saved file first and then appends the commands that succeed, so state survives across calls. |
| `state` | The full root state, `customDump`ed, after replaying an optional session file. |
| `screens` | Every screen path with its commands, arguments, help and summary keys — as above. |
| `docs` | Write the generated command reference (`docsPath`) from the registry. `--check` exits 1 when it is stale, which is what keeps it honest in CI. |
| `test [files…]` | Run `*.appctl` scenario files (by default all of `scenariosPath`), one PASS/FAIL line each. Finding no scenario files to run is a failure, not "0 passed". |
| `snapshots` | The view snapshot tests, on an iOS simulator; `--record` re-records the reference images. |
| `check` | The verification ladder below; `--ui` adds its last two rungs. |
| `app launch` / `app run` / `app state` / `app screens` | The same commands, against the real app on a simulator, through the in-app bridge. |
| `app test [files…]` | The scenario files, in the real app on a simulator: one fresh launch each, one PASS/FAIL/SKIP line each. `--record <mp4>` records the run, `--step-delay <s>` sends a line at a time so the recording can be followed. |

Exit codes are part of the contract: `0` everything ran and every `expect` passed; `1` a command or an `expect`
failed, or a step — `(launch)` included — did not settle; `2` a usage or parse error, the CLI's own command line
included; `3` an internal or environment error — a scenario file that does not exist, no scenario files to run,
no repo root, a build that failed.

Three runtime commands work on every screen: `expect k=v [k=v …]`, `advance <duration>` (the virtual clock
headlessly; in the running app, the app's real-time clock jumped forward, see [the bridge](#the-in-app-bridge)),
and `mock <client.method> <error>`.

Headless runs are deterministic by construction, so the same script always prints the same bytes — which is what
makes step output usable as a committed fixture. `HeadlessHost` runs everything on one serial executor and pins
exactly these dependencies of your store:

| Dependency | Headless value |
|---|---|
| `\.continuousClock` | a `TestClock` that only `advance` moves (counting its sleeps for `pending=`) |
| `\.uuid` | `.incrementing` |
| `\.date` | 2026-01-01T09:00:00Z, on every read |
| `\.withRandomNumberGenerator` | a SplitMix64 generator with a fixed seed |
| `\.timeZone`, `\.locale`, `\.calendar` | UTC, `en_US_POSIX`, and the Gregorian calendar in UTC |
| `\.mockLatency` | zero |
| `\.mockCallLog`, `\.mockFaults` | fresh for every run |

**Nothing else is pinned.** If your app uses `\.mainQueue`, `\.suspendingClock` or any other source of time, pin
it yourself in the closure you pass `HeadlessHost` — it runs after the table above, so it can override any of
it too — and give your mock backends fresh state there. Anything read around the dependency system (a formatter
built on `Locale.current`, say) is not pinned at all.

## The verification ladder

`check` runs the cheapest checks first and stops at the first failure, printing one line per rung:

| Rung | What runs |
|---|---|
| L0 | `swift build` for each package path in `packages` |
| L1 | `swift test` for each of those that has a `Tests` directory |
| L2 | every scenario file, in-process |
| docs | `docs --check`: the generated command reference is not stale |
| L3 (`--ui`) | the `*SnapshotTests` of each package path in `snapshotPackages`, on an iOS simulator |
| L4 (`--ui`) | the real app: built, launched seeded on a simulator, one scenario sent through the bridge, one screenshot |

The rule that makes this pay off: **verify at the cheapest rung that proves the change.** Logic and flows are
L1/L2 and take milliseconds; only a view change needs L3, and only the app shell, the bridge or navigation needs
L4. Everything the CLI writes goes under the config's `outputPath`, `.appctl/` by default: `logs/`,
`screenshots/`, `snapshot-failures/`, and `DerivedData/` for builds without XcodeBuildMCP. Keep it out of version
control.

**AgentCtl assumes no repository layout.** It finds the root by walking up from the working directory for the
config's `rootMarker` (your `.xcworkspace` or `.xcodeproj` unless you name another file), and every other path
comes from the config, relative to that root:

- `packages` and `snapshotPackages` are package paths, such as `Packages/Features/Auth`, or `.` for a package at
  the root. A package is named by its path's last component in reports and log file names. That is also its
  SwiftPM identity, so it is unique within one build graph.
- L0 and L1 run `swift build` / `swift test --package-path <path>` for each path in `packages`, and L1 runs only
  where `<path>/Tests` exists.
- L3 runs `xcodebuild test` inside `<path>` for each path in `snapshotPackages`, with `-only-testing:` for each
  of its `Tests/*SnapshotTests` directories. The scheme is the one `xcodebuild -list` names after the directory:
  `<name>`, or `<name>-Package` for a package with several products (a package with a single scheme uses it,
  whatever its name). Reference images live in `<path>/Tests/<Target>SnapshotTests/__Snapshots__/`, recorded on
  `snapshotSimulatorName` at `snapshotRuntimeMajor` (a reference image only compares on the device and iOS
  version it was recorded on). It drives recording and artifact collection through
  [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)'s
  `TEST_RUNNER_SNAPSHOT_TESTING_RECORD` and `TEST_RUNNER_SNAPSHOT_ARTIFACTS`.
- L4 needs a real Xcode `target` and `bundleID`, and takes its seed, its scenario and the screen the app must
  end on from the config's `appCheck`.

- `scenariosPath`, `docsPath` and `outputPath` default to `scenarios`, `docs/agent-commands.md` and `.appctl`.

The example app in this repository shows the headless end of this: TinyApp is a target of the package at the
root, so its config lists `packages: ["."]`, and `swift run tinyctl check` builds and tests this whole package,
runs TinyApp's scenarios and checks its docs. It has no Xcode project, so `app`, `snapshots` and `check --ui`
cannot work there; they are the parts of the CLI this repository does not exercise end to end.

## The coverage guards

`AgentCtlTestSupport` fails your build when the agent surface drifts from what the app actually does. Wire it
into your own test target — this is the package's own suite, run against the example app
([`CoverageTests.swift`](Tests/AgentCtlTests/CoverageTests.swift); `PackageRoot.scenarios` is a URL this
repository's tests compute, and yours would too):

```swift
static func coverage() throws -> AgentCoverage<TinyRoot> {
  try AgentCoverage(screens: TinyRoot.registry, scenarios: PackageRoot.scenarios) {
    TinyAppConfig.headless().makeRunner()
  }
}

@Test func everyCommandIsUsedByAScenario() throws {
  let missing = try Self.coverage().unusedCommands()
  #expect(missing.isEmpty, "commands not used by any scenario: \(missing.joined(separator: ", "))")
}
```

- `unusedCommands()` — a command no scenario ever sends.
- `undocumentedSummaryKeys()` — a key a run emits that the screen's `summaryKeys` does not list, which would
  make the generated reference a lie.
- `unvisitedScreens()` — a documented screen path no scenario reaches. A `<id>` segment matches any concrete
  one, so a variable path needs one scenario, not one per instance.

`AgentCoverage.init` throws `NoScenariosFound` when the scenarios directory holds no `*.appctl` files, because
all three guards would otherwise pass having examined nothing.

They are deliberately shallow: they check that a command *appears* in some script, not that its result was
asserted. A thin suite that touches everything once passes them.

## The in-app bridge

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

A Release build never names `AgentCtlBridge` or the config's target. `AgentLaunch` reads the launch arguments the
CLI's `app` subcommands pass: `-agent-port <n>` (default `BridgeDefaults.port`, 8765, which is also where the CLI
connects), `-appctl-seed "<script>"` (commands applied before the first real frame, so the app opens already in
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
launch arguments — is [CONTRACT.md §8](CONTRACT.md#8-the-in-app-bridge).

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

[`Examples/AgentShop`](Examples/AgentShop) is the showcase: a real iOS app (sign-in, onboarding, a shop with a
cart and checkout) with an Xcode project, 105 scenarios, UI tests generated from them, and the benchmark behind
[the numbers above](#how-much-faster). It is its own package, depending on this one by path. See
[its README](Examples/AgentShop/README.md).

## Status

Version 0.3, extracted from the app it was built for. The two example apps in this repository are the integrations
CI exercises, and the API may still change between minor versions before 1.0. MIT licensed.
