import Foundation
import AgentCtlCore
import AgentCtlTCA
import AppFeature
import AccountClient
import AuthClient
import CartClient
import CatalogClient
import ComposableArchitecture
import Models
import OrdersClient
import SessionClient

/// Everything AgentCtl needs to know about AgentShop.
public enum AgentShopConfig {
  /// How this example spells the CLI everywhere it names itself: the wrapper script beside `Package.swift`, which
  /// rebuilds `agentshopctl` before running it. Never the bare executable, which is not on anyone's PATH.
  static let invocation = "./appctl"

  /// Where the scenario files live, as a reader should type it.
  static let scenariosGlob = "scenarios/*.appctl"

  /// Every screen AgentShop's agent layer can reach, for docs and `appctl screens`.
  public static var screens: [ScreenDoc] { AppFeature.registry }

  /// Every method `mock` can fail, for docs and for each host's `ScriptRunner` (which doesn't know about
  /// AgentShop's clients).
  public static var mockMethods: [MockMethod] {
    AuthClient.mockMethods + AccountClient.mockMethods + CatalogClient.mockMethods + CartClient.mockMethods
      + OrdersClient.mockMethods
  }

  /// The host-written prose in `agent-commands.md`.
  public static let docsText = DocsText(
    title: "Agent commands",
    intro: "Every screen of AgentShop can be driven with the same commands headlessly (`\(invocation) run \"…\"`),\n"
      + "in scenario files (`\(scenariosGlob)`), at launch (`-appctl-seed`) and in the running app "
      + "(`\(invocation) app run \"…\"`).",
    usageExamples: [
      "\(invocation) run \"login-as alice; open 1003; cancel\"              # cancel a pending order",
      "\(invocation) run \"use-otp; email alice@example.com; send; advance 30s; resend\"",
      "\(invocation) run \"mock orders.fetchOrders network; login-as alice; retry\"",
      "\(invocation) run --session .appctl/s.session \"register\"   # keep going from the same state next time",
      "\(invocation) app launch --no-build --seed \"login-as bob; tab profile\"   # the real app, already there",
    ],
    invocation: invocation,
    // A real step from `./appctl run "…; submit"` on the login screen, so the syntax section shows AgentShop's
    // own output rather than `screen=<path> <key>=<value>`.
    exampleCommand: "submit",
    exampleStep: "screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders",
    scenariosGlob: scenariosGlob,
    mockExample: "mock orders.fetchOrders network",
    appendix: [
      "## Test accounts",
      "",
      "| Account | Password | Notes |",
      "|---|---|---|",
      "| `\(MockAccounts.alice.user.email)` | `\(MockAccounts.alice.password ?? "")` | 3 orders: #1001 delivered, #1002 shipped, #1003 pending |",
      "| `\(MockAccounts.bob.user.email)` | `\(MockAccounts.bob.password ?? "")` | no orders |",
      "| `\(MockAccounts.locked.user.email)` | any | always `accountLocked` |",
      "",
      "The OTP code is always `\(MockAccounts.otpCode)` and the password-reset code is always `\(MockAccounts.resetCode)`.",
    ]
  )

  /// The example commands in the CLI's own help pages, written in AgentShop's vocabulary: its accounts, its
  /// screen paths and its scenario files, rather than the package's `<command>` placeholders.
  public static let help = HelpExamples(
    invocation: invocation,
    note: "Always call it through the \(invocation) wrapper at the repo root, which rebuilds the CLI incrementally.",
    runScripts: ["login-as alice; open 1003; cancel", "email alice@example.com", "expect screen=auth/login"],
    scenarioPath: "scenarios/shop-order-cancel.appctl",
    appSeeds: ["login-as alice", "login-as bob; tab profile"],
    appScripts: ["open 1003; cancel; expect status=cancelled", "tab profile"]
  )

  /// Everything the CLI needs: `appctl` is `AgentCtl.run(config: AgentShopConfig.appCtl)`.
  @MainActor
  public static var appCtl: AppCtlConfig<AppFeature> {
    AppCtlConfig(
      name: "AgentShop",
      // The root is `Examples/AgentShop`: the CLI walks up to the directory that holds this project.
      target: .project("App/AgentShop.xcodeproj", scheme: "AgentShop"),
      bundleID: "dev.olbartek.AgentShop",
      // One package holds the whole app, so `check` builds and tests just this one. It has no snapshot tests.
      packages: ["."],
      snapshotPackages: [],
      simulatorName: "iPhone 17 Pro",
      snapshotRuntimeMajor: 18,
      scenariosPath: "scenarios",
      docsPath: "agent-commands.md",
      appCheck: AppCheck(seed: "login-as alice", scenario: "shop-order-cancel", expectScreen: "home/orders"),
      help: help,
      mockMethods: mockMethods,
      docsText: docsText,
      screens: screens,
      makeHeadless: { headless() },
      makeLive: { latency in live(latency: latency) },
      clearSession: { SessionStorage.liveValue.store(nil) }
    )
  }

  @MainActor
  public static func headless() -> HeadlessHost<AppFeature> {
    HeadlessHost(initialState: { AppFeature.State() }, reducer: { AppFeature() }, mockMethods: mockMethods) { deps, env in
      // The clients' liveValues are the in-memory mocks. Set them explicitly so the app behaves the same
      // in a test process, where dependencies default to their (unimplemented) testValues.
      deps.authClient = .liveValue
      deps.sessionClient = .liveValue
      deps.ordersClient = .liveValue
      deps.accountClient = .liveValue
      deps.catalogClient = .liveValue
      deps.cartClient = .liveValue
      deps.sessionStorage = .inMemory()
      deps.authBackend = AuthBackend(clock: env.clock)
      deps.ordersBackend = OrdersBackend()
      deps.accountBackend = AccountBackend()
    }
  }

  @MainActor
  public static func live(latency: MockLatency, sessionStorage: SessionStorage = .liveValue) -> LiveHost<AppFeature> {
    LiveHost(
      initialState: { AppFeature.State() }, reducer: { AppFeature() }, latency: latency, mockMethods: mockMethods
    ) { deps, env in
      deps.authClient = .liveValue
      deps.sessionClient = .liveValue
      deps.ordersClient = .liveValue
      deps.accountClient = .liveValue
      deps.catalogClient = .liveValue
      deps.cartClient = .liveValue
      deps.sessionStorage = sessionStorage
      deps.authBackend = AuthBackend(clock: env.clock)
      deps.ordersBackend = OrdersBackend()
      deps.accountBackend = AccountBackend()
      // `-mock-fault <method>#<n>=<code>`: how a UI test, which cannot send `mock`, fails a backend call.
      deps.scheduledFaults = ScheduledFaults(arguments: ProcessInfo.processInfo.arguments)
    }
  }
}
