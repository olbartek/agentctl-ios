#if DEBUG
  import AgentCtlCore
  import AgentCtlTCA
  import ComposableArchitecture
  import Foundation
  import Observation

  /// Starts AgentBridge in DEBUG builds of the app and applies launch seeding (spec §5.6).
  ///
  /// Everything app-specific comes from the ``AppCtlConfig`` the host hands it — the same value its CLI runs
  /// on — so the app shell's integration is one line:
  ///
  /// ```swift
  /// @State private var launch = AgentLaunch(config: MyAppConfig.appCtl)
  /// ```
  ///
  /// Launch arguments:
  /// - `-agent-port <n>`: the bridge port (default 8765).
  /// - `-appctl-seed "<script>"`: commands run before the first real frame; the app shows a splash until then.
  /// - `-mock-latency <ms>`: fixed mock latency (default: the config's live latency).
  /// - `-clear-session`: `config.clearSession()` before the app launches.
  @MainActor
  @Observable
  public final class AgentLaunch<Root: Reducer & AgentContainer>
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    public struct Options: Equatable, Sendable {
      public var port: UInt16 = 8765
      public var seed: String?
      public var latency: MockLatency?
      public var clearSession = false

      public init(arguments: [String]) {
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

    public let options: Options
    public let store: Store<Root.State, Root.Action>
    /// `false` while a launch seed is being applied.
    public private(set) var isReady: Bool
    @ObservationIgnored private let app: LiveHost<Root>
    /// The screens `GET /screens` renders, from the config; headlessly there is no registry to ask.
    @ObservationIgnored private let screens: [ScreenDoc]
    @ObservationIgnored private var server: BridgeServer?
    @ObservationIgnored private var router: BridgeRouter<Root>?

    public init(config: AppCtlConfig<Root>, arguments: [String] = ProcessInfo.processInfo.arguments) {
      let options = Options(arguments: arguments)
      if options.clearSession {
        config.clearSession()
      }
      self.options = options
      self.screens = config.screens
      self.app = config.makeLive(options.latency ?? .liveValue)
      self.store = app.store
      self.isReady = options.seed == nil
    }

    /// Applies the seed (if any), then starts the bridge, so the bridge's first answer means the app is ready.
    /// Call once, from the root view's `.task`.
    public func start() async {
      guard server == nil else { return }
      let router = BridgeRouter(
        runner: app.makeRunner(synthesizesAppearance: false),
        screensText: { [screens] in ScreensRenderer.render(screens) }
      )
      let server = BridgeServer(handler: { await router.handle($0) })
      self.router = router
      self.server = server
      if let seed = options.seed {
        let seeder = app.makeRunner(synthesizesAppearance: true)
        var steps = [await seeder.launch()]
        let result = await seeder.run(seed)
        steps += result.steps
        print("AgentBridge: seed\n" + StepFormatter.text(steps))
        isReady = true
      }
      do {
        let port = try await server.start(port: options.port)
        print("AgentBridge: listening on 127.0.0.1:\(port)")
      } catch {
        print("AgentBridge: could not listen on port \(options.port): \(error)")
      }
    }
  }
#endif
