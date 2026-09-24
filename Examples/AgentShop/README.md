# AgentShop

The showcase app for [AgentCtl](../../README.md): a small but complete shop, built with TCA, whose 105 scenario files
run **unchanged** in three modes. It exists to show, and to measure, what driving an app through its agent layer
buys you over UI tests.

What the app does, with screenshots: [`docs/APP.md`](docs/APP.md).

| Group | Screens | Scenarios |
|---|---|---|
| **Authentication** | login, one-time code, sign-up, email verification, password reset, profile and log-out | 35 |
| **Onboarding** | welcome carousel, interests (2–4), shipping address, notifications — once per new account | 26 |
| **Shop** | feed (filter, search, sort), product (sizes, quantity, favorite), cart (promo codes), checkout (saved address, express shipping, card or Apple Pay), confirmation, orders | 44 |

Everything behind the screens is mocked in memory (`Sources/*Client`), and every mocked call can be made to fail
from a script (`mock orders.placeOrder network`). The accounts:

| Account | Password | |
|---|---|---|
| `alice@example.com` | `Passw0rd!` | onboarded, three orders, a saved address |
| `bob@example.com` | `Hunter22x` | onboarded, no orders, no address |
| `nina@example.com` | `Passw0rd!` | not onboarded yet: signing in starts onboarding |
| `locked@example.com` | any | always locked |

Promo codes `SAVE10` and `HALF`; card `4000 0000 0000 0002` is always declined. The full command reference is
[`agent-commands.md`](agent-commands.md), generated from the `+Agent.swift` files.

## The three modes

The same file, [`scenarios/shop-checkout-happy-path.appctl`](scenarios/shop-checkout-happy-path.appctl), three ways:

```bash
cd Examples/AgentShop

# 1. Headless: on the Mac, no simulator, no views.
./appctl test scenarios/shop-checkout-happy-path.appctl

# 2. The real app on a simulator, driven through its DEBUG-only agent bridge.
./appctl app launch --clear-session --latency 0 --port 8799
./appctl app run --port 8799 "$(cat scenarios/shop-checkout-happy-path.appctl)"

# 3. The XCUITest generated from it: taps and typing through the real UI.
xcodebuild test -project App/AgentShop.xcodeproj -scheme AgentShop \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AgentShopUITests/ShopUITests/test_checkout_happy_path
```

(`--port 8799`: the bridge's default, 8765, is also what `adb` forwards for Android work; any free port works.)

### How the UI tests are generated

Hand-writing a hundred UI tests that do exactly what the scenarios do would be slow and would drift.
[`bench/gen_uitests.py`](bench/gen_uitests.py) generates them instead:

1. It runs each scenario headlessly with `--json`, so it knows the screen every command is sent on.
2. Each command becomes one call to [`ShopUITestCase`](App/AgentShopUITests/ShopUITestCase.swift): a tap, some
   typing or a switch, found by an accessibility identifier derived from the command
   ([`DesignSystem/UITestIdentifiers.swift`](Sources/DesignSystem/UITestIdentifiers.swift)): `Login.submit`,
   `ShopFeed.open.101`, `screen:home/cart`, `error:paymentDeclined`.
3. `expect` becomes waits for what the screen shows. `mock` becomes a launch argument that fails the same call:
   `-mock-fault orders.placeOrder#1=network`.

99 of the 105 scenarios become UI tests. The other six move a virtual clock (`advance 30s`) or relaunch (`reset`),
which a UI test can only do by really waiting. They stay headless.

```bash
python3 bench/gen_uitests.py          # after changing a scenario or a screen's commands
python3 bench/gen_uitests.py --check  # CI: fails if the generated tests are stale
```

The UI tests needed what every UI suite needs: a way past iOS's "Save Password?" sheet, scrolling out from under
the keyboard, and a `-ui-testing` launch flag that turns off password autofill, which otherwise types over the
test. None of that exists in the headless run, which has no views at all.

## The benchmark and the video

```bash
python3 bench/bench.py            # every group, every mode: about 45 minutes, most of it the UI tests
python3 bench/bench.py --quick --groups auth
python3 bench/video.py            # three scenarios recorded side by side, with timers
```

`bench.py` writes [`docs/benchmarks/<date>-agentshop.md`](../../docs/benchmarks) and times these:

- every comparable scenario in every mode;
- each group as one headless process;
- the loop an agent actually runs: change a line of a reducer, then verify it headlessly or through the UI.

`video.py` writes `.bench/video/agentshop-three-modes.mp4`.

## Layout

| Path | What |
|---|---|
| `Package.swift` | One package: models, design system, mocked clients, features, the CLI (`shopctl`). It depends on AgentCtl **by path**, so the repository must be checked out as `agentctl-ios` (the `git clone` default), which is the package identity the manifest names. |
| `Sources/<Feature>/<Screen>+Agent.swift` | Each screen's agent surface: path, summary, commands. |
| `Sources/AgentShopCtl/Config.swift` | The whole AgentCtl integration: one `AppCtlConfig`, and the headless and live hosts. |
| `App/` | The app shell (`AgentShopApp.swift`), its Xcode project and the UI tests. |
| `scenarios/` | `<group>-<name>.appctl`, 105 of them. |
| `bench/` | The UI test generator, the benchmark, the video recorder and composer, the screenshot script. |
| `docs/` | [`APP.md`](docs/APP.md), the app with screenshots. |
| `appctl` | The wrapper: rebuilds `shopctl`, then runs it. |
