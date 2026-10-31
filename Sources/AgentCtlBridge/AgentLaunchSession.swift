#if DEBUG
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation

  /// Starts the agent bridge in DEBUG builds of the app and applies launch seeding, with no UI framework and from
  /// iOS 16: what ``AgentLaunch`` does, minus its `@Observable` properties. A UIKit app, or any app on iOS 16, keeps
  /// one in its app delegate or scene delegate and hears about its two changes through ``onAppChange`` and ``onReady``:
  ///
  /// ```swift
  /// let session = AgentLaunchSession(config: MyAppConfig.appCtl)
  /// session.onAppChange = { [weak self] app in self?.showRoot(app) }   // `device relaunch` made a new one
  /// session.onReady = { [weak self] in self?.hideSplash() }            // the launch seed is applied
  /// showRoot(session.app)
  /// Task { await session.start() }
  /// ```
  ///
  /// A SwiftUI app on iOS 17 or later uses ``AgentLaunch``, which wraps a session. The launch arguments are those of
  /// ``AgentLaunchOptions`` (CONTRACT.md §8.2): without a well-formed `-agent-token` there is no bridge, and every
  /// other argument is ignored.
  @MainActor
  public final class AgentLaunchSession<Driver: AgentDriver> {
    public let options: AgentLaunchOptions
    /// What the root view shows — the store of a TCA app, the coordinator of an MVVM-C app. `device relaunch`
    /// replaces it, and calls ``onAppChange`` with the new one.
    public private(set) var app: Driver.App {
      didSet { onAppChange?(app) }
    }
    /// `false` while a launch seed is being applied; ``onReady`` is called when it becomes `true`.
    public private(set) var isReady: Bool {
      didSet { if isReady && !oldValue { onReady?() } }
    }
    /// Called on the main actor with the new ``app`` after a `device relaunch`: show it in place of the old one.
    public var onAppChange: (@MainActor (Driver.App) -> Void)?
    /// Called on the main actor once the launch seed is applied: show the app in place of a splash.
    public var onReady: (@MainActor () -> Void)?

    private let host: LiveHost<Driver>
    /// The screens `GET /screens` renders, from the config; headlessly there is no registry to ask.
    private let screens: [ScreenDoc]
    /// The host's `mock` example, so the bridge's `/screens` lists the runtime commands exactly as the CLI does.
    private let mockExample: String
    private let deviceSurface: AgentDevice.Surface
    private var server: BridgeServer?
    private var router: BridgeRouter<Driver>?
    /// The port the bridge listens on, once it does. Tests only: `-agent-port 0` picks a free one.
    private(set) var port: UInt16?

    /// Reads the launch arguments, clears the session if `-clear-session` asks (with a token), and builds the app
    /// over the config's live host. Nothing listens until ``start()``.
    public init(config: AppCtlConfig<Driver>, arguments: [String] = ProcessInfo.processInfo.arguments) {
      let options = AgentLaunchOptions(arguments: arguments)
      if options.clearSession {
        config.clearSession()
      }
      self.options = options
      self.screens = config.screens
      self.mockExample = config.docsText.mockExample
      self.deviceSurface = config.device.surface
      let host = config.makeLive(options.latency ?? .liveValue)
      #if canImport(UIKit)
        if host.isUIIdle == nil { host.isUIIdle = UIActivity.isIdle }
      #endif
      self.host = host
      self.app = host.driver.app
      self.isReady = options.seed == nil
      host.driver.onRelaunch = { [weak self, driver = host.driver] in self?.app = driver.app }
    }

    /// Applies the seed (if any), then starts the bridge, so the bridge's first answer means the app is ready.
    /// Call once, when the app's first screen is up: from the root view's `.task`, or after the window is shown.
    public func start() async {
      guard server == nil else { return }
      guard let token = options.token else {
        print("AgentCtlBridge: no -agent-token; not listening")
        return
      }
      let router = BridgeRouter(
        runner: host.makeRunner(synthesizesAppearance: false),
        screensText: { [screens, mockExample, deviceSurface] in
          ScreensRenderer.render(screens, mockExample: mockExample, device: deviceSurface)
        }
      )
      let server = BridgeServer(token: token, handler: { try await router.handle($0) })
      if let seed = options.seed {
        do {
          print(try await Self.applySeed(seed, with: host.makeRunner(synthesizesAppearance: true)).log)
        } catch {
          // The launch itself was cancelled (its view went away): no bridge, and a later start applies the seed anew.
          print("AgentCtlBridge: seed cancelled; not listening")
          return
        }
        isReady = true
      }
      self.router = router
      self.server = server
      do {
        let port = try await server.start(port: options.port)
        self.port = port
        print("AgentCtlBridge: listening on 127.0.0.1:\(port)")
      } catch {
        print("AgentCtlBridge: could not listen on port \(options.port): \(error)")
      }
    }

    /// Whether the bridge is listening.
    var isListening: Bool { server?.listener != nil }

    /// Stops the bridge. Tests only: an app's bridge lives as long as the app.
    func stop() {
      server?.stop()
      server = nil
      router = nil
      port = nil
    }

    /// Applies a launch seed: the `(launch)` step, then the seed's commands. A seed is a script, so it fails the
    /// way a script does (CONTRACT.md §5): it stops at its first failing step, and a launch that did not settle
    /// fails it before its first command runs (§3.4). Returns that status and the block the app logs; throws
    /// `CancellationError` when the launch is cancelled, which aborts it.
    static func applySeed(
      _ seed: String, with runner: ScriptRunner<Driver>
    ) async throws(CancellationError) -> (status: RunStatus, log: String) {
      let launch = await runner.launch()
      // A launch cut short by cancellation did not fail: it was abandoned.
      if Task.isCancelled { throw CancellationError() }
      var steps = [launch.step]
      var status = launch.status
      var message: String?
      if launch.status == .ok {
        let result = try await runner.run(seed)
        steps += result.steps
        status = result.status
        message = result.message
      }
      let outcome = status == .ok ? "applied" : "FAILED (exit \(status.rawValue))"
      var log = "AgentCtlBridge: seed \(outcome)\n" + StepFormatter.text(steps)
      if let message {
        log += "\nerror: \(message)"
      }
      return (status, log)
    }
  }

  /// The launch arguments of CONTRACT.md §8.2, as the CLI's `app` subcommands pass them:
  /// - `-agent-token <t>`: the launch's token, 32 lowercase hex characters (``AgentLaunchArguments/makeToken()``).
  ///   Without a well-formed one there is no bridge, and every argument below is ignored.
  /// - `-agent-port <n>`: the bridge port (default ``BridgeDefaults/port``, 8765).
  /// - `-appctl-seed "<script>"`: commands run before the first real frame; the app shows a splash until then.
  /// - `-mock-latency <ms>`: fixed mock latency (default: the config's live latency).
  /// - `-clear-session`: `config.clearSession()` before the app launches.
  public struct AgentLaunchOptions: Equatable, Sendable {
    /// The launch's token, when it passed a well-formed one; `nil` means no bridge, and the defaults below.
    public var token: String?
    public var port: UInt16 = BridgeDefaults.port
    public var seed: String?
    public var latency: MockLatency?
    public var clearSession = false

    public init(arguments: [String]) {
      // Without a token, nothing else is read: a launch the CLI did not make gets the plain defaults (CONTRACT.md §8.2).
      guard let token = AgentLaunchArguments.token(arguments) else { return }
      self.token = token
      var iterator = arguments.dropFirst().makeIterator()
      while let argument = iterator.next() {
        switch argument {
        case "-agent-port": port = iterator.next().flatMap(UInt16.init) ?? port
        case "-appctl-seed": seed = iterator.next()
        case "-mock-latency": latency = iterator.next().flatMap(Int.init).map(MockLatency.milliseconds)
        case "-clear-session": clearSession = true
        default: continue
        }
      }
    }
  }

  /// The token never appears in a description or a dump of the options.
  extension AgentLaunchOptions: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
      "Options(token: \(token == nil ? "nil" : BridgeToken.redacted), port: \(port), seed: \(seed.map { "\"\($0)\"" } ?? "nil"), "
        + "latency: \(latency.map { "\($0)" } ?? "nil"), clearSession: \(clearSession))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
      Mirror(
        self,
        children: [
          "token": token.map { _ in BridgeToken.redacted } as Any, "port": port, "seed": seed as Any,
          "latency": latency as Any, "clearSession": clearSession,
        ]
      )
    }
  }

  /// The launch arguments the CLI's `app` subcommands pass, read without naming an app's driver.
  public enum AgentLaunchArguments {
    /// Whether this launch asks for the bridge: it passed a well-formed `-agent-token`, as the CLI's `app` subcommands
    /// always do and any other launch (⌘R from Xcode included) does not. A UI test that launches the app itself passes
    /// one from ``makeToken()``.
    public static func isRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
      token(arguments) != nil
    }

    /// A fresh token for a launch: 32 lowercase hex characters from the system's secure random generator. The CLI
    /// makes one for every launch; a UI test that launches the app with `-clear-session` or `-appctl-seed` passes one
    /// as well, or the app ignores them:
    ///
    /// ```swift
    /// app.launchArguments = ["-agent-token", AgentLaunchArguments.makeToken(), "-clear-session"]
    /// ```
    public static func makeToken() -> String {
      BridgeToken.make()
    }

    /// The token after `-agent-token` (the last, if there are several), when it is well-formed: exactly 32 lowercase
    /// hex characters.
    static func token(_ arguments: [String]) -> String? {
      let values = arguments.dropFirst().indices.filter { arguments[$0] == BridgeToken.argument }
      guard let last = values.last, arguments.indices.contains(last + 1) else { return nil }
      let token = arguments[last + 1]
      return BridgeToken.isWellFormed(token) ? token : nil
    }
  }
#endif
