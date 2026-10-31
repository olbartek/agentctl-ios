import AgentCtlCore
import AgentCtlTCA
import AgentCtlTestSupport
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

/// A one-screen app that uses every part of the device: a camera permission, Face ID, connectivity and location
/// it observes, the scene phase, links, a push and a mocked call.
@Reducer
struct Gadget {
  @ObservableState
  struct State: Equatable {
    var camera = "unasked"
    var faceID = "none"
    var online = "unknown"
    var location = "unknown"
    var phase = "none"
    var link = "none"
    var pings = 0
    var fetched = "none"
  }

  enum Action: Equatable, Sendable {
    case onAppear
    case cameraTapped
    case cameraAnswered(AgentDevice.PermissionStatus)
    case unlockTapped
    case unlocked(AgentDevice.BiometryResult)
    case onlineChanged(Bool)
    case locationChanged(AgentDevice.Location?)
    case phaseChanged(AgentDevice.Phase)
    case linkOpened(String)
    case pinged
    case fetchTapped
    case fetched(String)
  }

  @Dependency(\.agentDevice) var device

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .merge(
          .run { [device] send in for await online in device.onlineUpdates() { await send(.onlineChanged(online)) } },
          .run { [device] send in for await location in device.locationUpdates() { await send(.locationChanged(location)) } }
        )
      case .cameraTapped:
        return .run { [device] send in await send(.cameraAnswered(await device.requestPermission("camera"))) }
      case let .cameraAnswered(status):
        state.camera = status.rawValue
      case .unlockTapped:
        return .run { [device] send in await send(.unlocked(await device.authenticateBiometry())) }
      case let .unlocked(result):
        state.faceID = "\(result)"
      case let .onlineChanged(online):
        state.online = online ? "yes" : "no"
      case let .locationChanged(location):
        state.location = location.map { "\($0.latitude),\($0.longitude)" } ?? "none"
      case let .phaseChanged(phase):
        state.phase = phase.rawValue
      case let .linkOpened(link):
        state.link = link
      case .pinged:
        state.pings += 1
      case .fetchTapped:
        return .run { send in
          do {
            try await mockCall("gadget.fetch", error: { GadgetError(code: $0) }) {}
            await send(.fetched("ok"))
          } catch let error as GadgetError {
            await send(.fetched(error.code))
          }
        }
      case let .fetched(result):
        state.fetched = result
      }
      return .none
    }
  }

  struct GadgetError: Error {
    var code: String
  }
}

extension Gadget: AgentScreen, AgentContainer {
  static let screenPaths = ["gadget"]
  static func screenPath(_ state: State) -> String { "gadget" }
  static let summaryKeys = ["camera", "faceID", "online", "location", "phase", "link", "pings", "fetched"]
  static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("camera", state.camera), SummaryItem("faceID", state.faceID), SummaryItem("online", state.online),
      SummaryItem("location", state.location), SummaryItem("phase", state.phase), SummaryItem("link", state.link),
      SummaryItem("pings", state.pings), SummaryItem("fetched", state.fetched),
    ]
  }
  static func errorCode(_ state: State) -> String? { nil }
  static let onAppear: Action? = .onAppear
  static let commands: [AgentCommand<State, Action>] = [
    .action("camera", help: "Ask for the camera.", .cameraTapped),
    .action("unlock", help: "Unlock with Face ID.", .unlockTapped),
    .action("fetch", help: "Fetch.", .fetchTapped),
  ]
  static var registry: [ScreenDoc] { screenDocs }

  static let device = AgentDeviceConfig<Action>(
    permissions: ["camera", "location"],
    openURL: { $0.scheme == "gadget" ? .linkOpened($0.absoluteString) : nil },
    pushes: [AgentDevice.Push("ping", help: "A ping.", received: .pinged, opened: .linkOpened("ping"))],
    scenePhase: { .phaseChanged($0) },
    relaunch: true,
    offlineErrorCode: "offline",
    location: true,
    biometry: true
  )

  @MainActor
  static func host(device: AgentDeviceConfig<Action> = Gadget.device) -> HeadlessHost<AgentStoreDriver<Gadget>> {
    HeadlessHost(
      initialState: { State() }, reducer: { Gadget() },
      mockMethods: [MockMethod("gadget.fetch", errorCodes: ["offline", "boom"])], device: device
    ) { _, _ in }
  }
}

@MainActor
final class HearingOrder {
  var indices: [Int] = []
}

/// What this guards: the `device` runtime command (CONTRACT.md §2.4). Its texts are shared with agentctl-android
/// byte for byte.
extension AgentCtlSuite {
  @MainActor
  struct DeviceTests {
    /// The steps of `script` after `(launch)`, as text.
    func run(_ script: String, host: HeadlessHost<AgentStoreDriver<Gadget>> = Gadget.host()) async throws -> (text: String, status: RunStatus) {
      try await serially {
        let runner = host.makeRunner()
        _ = await runner.launch()
        let result = try await runner.run(script)
        return (StepFormatter.text(result.steps), result.status)
      }
    }

    static let start = "camera=unasked faceID=none online=yes location=none phase=none link=none pings=0 fetched=none"

    @Test func aPermissionRequestShowsAPromptUntilAnswered() async throws {
      let (text, status) = try await run("camera; expect prompt=camera; device prompt allow; expect prompt=none camera=granted; camera")
      #expect(status == .ok)
      #expect(
        text == """
          > camera
            screen=gadget \(Self.start) prompt=camera
          > expect prompt=camera
            screen=gadget \(Self.start) prompt=camera
          > device prompt allow
            screen=gadget camera=granted faceID=none online=yes location=none phase=none link=none pings=0 fetched=none
          > expect prompt=none camera=granted
            screen=gadget camera=granted faceID=none online=yes location=none phase=none link=none pings=0 fetched=none
          > camera
            screen=gadget camera=granted faceID=none online=yes location=none phase=none link=none pings=0 fetched=none
          """
      )
    }

    @Test func aSetPermissionAnswersWithoutAPrompt() async throws {
      let (text, _) = try await run("device permission camera denied; camera; expect camera=denied prompt=none")
      #expect(text.contains("> camera\n  screen=gadget camera=denied"))
      #expect(!text.contains(" prompt=camera"))
    }

    @Test func promptsQueueAndLimitedIsAnAnswer() async throws {
      let (text, status) = try await run("camera; camera; device prompt limited; expect prompt=camera camera=limited; device prompt deny; expect prompt=none camera=denied")
      #expect(status == .ok, "\(text)")
    }

    @Test func permissionAndPromptErrors() async throws {
      let cases: [(String, RunStatus, String)] = [
        ("device permission camera", .usage,
         "usage: device permission <service> <not-determined|granted|denied|limited>; services: camera, location"),
        ("device permission camera maybe", .usage,
         "usage: device permission <service> <not-determined|granted|denied|limited>; services: camera, location"),
        ("device permission mic granted", .failed, "unknown permission 'mic'; services: camera, location"),
        ("camera; device permission camera granted", .failed,
         "device permission: a prompt for camera is pending; answer it with device prompt allow|deny|limited"),
        ("device prompt allow", .failed, "device prompt: no prompt is pending"),
        ("device prompt yes", .usage, "usage: device prompt <allow|deny|limited>"),
        ("unlock; device prompt allow", .failed,
         "device prompt: the pending prompt is biometry; answer it with device biometry match|fail"),
      ]
      for (script, expected, message) in cases {
        let (text, status) = try await run(script)
        #expect(status == expected, "\(script)")
        #expect(text.hasSuffix("  FAIL \(message)"), "\(script):\n\(text)")
      }
    }

    @Test func commonErrors() async throws {
      let available = "permission, prompt, open-url, push, background, foreground, relaunch, network, location, biometry"
      let cases: [(String, String)] = [
        ("device", "usage: device <subcommand>; available: \(available)"),
        ("device warp", "unknown device command 'warp'; available: \(available)"),
        ("device background now", "usage: device background"),
        ("device relaunch x", "usage: device relaunch"),
        ("device network slow", "usage: device network <online|offline>"),
        ("device location 52.2;21", "usage: device location <lat>,<lon> or none, e.g. 52.2297,21.0122"),
        ("device location 91,0", "usage: device location <lat>,<lon> or none, e.g. 52.2297,21.0122"),
        ("device location 1e2,0", "usage: device location <lat>,<lon> or none, e.g. 52.2297,21.0122"),
        ("device location \"52.2, 21\"", "usage: device location <lat>,<lon> or none, e.g. 52.2297,21.0122"),
        ("device biometry maybe", "usage: device biometry <enrolled|unenrolled|match|fail>"),
        ("device open-url nope", "usage: device open-url <url>"),
        ("device push ping later", "usage: device push <name> [tap]; pushes: ping"),
      ]
      for (script, message) in cases {
        let (text, status) = try await run(script)
        #expect(status == .usage, "\(script)")
        #expect(text.hasSuffix("  FAIL \(message)"), "\(script):\n\(text)")
      }
    }

    @Test func aSubcommandTheAppDidNotConfigure() async throws {
      let host = Gadget.host(device: AgentDeviceConfig(openURL: { _ in nil }))
      let (text, status) = try await run("device push ping", host: host)
      #expect(status == .usage)
      #expect(text.hasSuffix("  FAIL device push is not configured by this app; available: open-url"))
    }

    @Test func noDeviceConfigurationMeansNoDeviceCommand() async throws {
      let (text, status) = try await run("device network offline", host: Gadget.host(device: .none))
      #expect(status == .failed)
      #expect(text.hasSuffix("  FAIL unknown command 'device' on gadget. Valid here: camera, unlock, fetch, expect, advance, mock, wait"))
      let (configured, _) = try await run("nope")
      #expect(configured.hasSuffix("Valid here: camera, unlock, fetch, expect, advance, mock, wait, device"))
    }

    @Test func linksAndPushes() async throws {
      let (text, status) = try await run(
        "device open-url gadget://x/1; expect link=gadget://x/1; device push ping; expect pings=1 link=gadget://x/1; "
          + "device push ping tap; expect pings=1 link=ping"
      )
      #expect(status == .ok, "\(text)")
      let (unhandled, failed) = try await run("device open-url \"https://example.com/a b\"")
      #expect(failed == .usage, "a space is not a URL: \(unhandled)")
      let (other, otherStatus) = try await run("device open-url https://example.com")
      #expect(otherStatus == .failed)
      #expect(other.hasSuffix("  FAIL device open-url: the app does not handle https://example.com"))
      let (unknown, unknownStatus) = try await run("device push pong")
      #expect(unknownStatus == .failed)
      #expect(unknown.hasSuffix("  FAIL unknown push 'pong'; pushes: ping"))
    }

    /// Both ports accept and refuse the same link texts (agentctl-android's java.net.URI and Swift's strict URL).
    @Test func linkValidityMatchesTheKotlinPort() async throws {
      for url in ["gadget://[::1]:8080/a", "gadget://x/a%20b?q=1#f", "gadget:x"] {
        let (text, status) = try await run("device open-url \(url)")
        #expect(status == .ok, "\(url) is a link:\n\(text)")
      }
      for url in ["gadget://x/é", "gadget://x/2?x=[1]", "gadget://x/%zz", "gadget://x/２", "gadget://[x/1", "gadget:"] {
        let (text, status) = try await run("device open-url \(url)")
        #expect(status == .usage, "\(url) is not a link:\n\(text)")
      }
    }

    @Test func screenCommandsFailInTheBackground() async throws {
      let (text, status) = try await run("device background; expect phase=background; camera")
      #expect(status == .failed)
      #expect(text.hasSuffix("  FAIL camera is unavailable: the app is in the background (device foreground first)"))
      let (back, ok) = try await run("device background; device foreground; expect phase=foreground; camera; expect prompt=camera")
      #expect(ok == .ok, "\(back)")
    }

    @Test func networkOfflineFailsEveryMockedCall() async throws {
      let (text, status) = try await run(
        "mock gadget.fetch boom; device network offline; expect online=no; fetch; expect fetched=offline call=gadget.fetch; "
          + "device network online; expect online=yes; fetch; expect fetched=boom; fetch; expect fetched=ok"
      )
      #expect(status == .ok, "the armed fault outlives the offline call:\n\(text)")
    }

    @Test func location() async throws {
      let (text, status) = try await run(
        "device location 52.2297,21.0122; expect location=52.2297,21.0122; device location -33,-70.5; "
          + "expect location=-33.0,-70.5; device location none; expect location=none"
      )
      #expect(status == .ok, "\(text)")
    }

    @Test func biometry() async throws {
      let (text, status) = try await run(
        "unlock; expect prompt=biometry; device biometry match; expect faceID=success prompt=none; "
          + "unlock; device biometry fail; expect faceID=failure; "
          + "device biometry unenrolled; unlock; expect faceID=unavailable prompt=none; device biometry enrolled"
      )
      #expect(status == .ok, "\(text)")
      let (none, failed) = try await run("device biometry match")
      #expect(failed == .failed)
      #expect(none.hasSuffix("  FAIL device biometry: no biometric prompt is pending"))
      let (other, _) = try await run("camera; device biometry fail")
      #expect(other.hasSuffix("  FAIL device biometry: no biometric prompt is pending"))
    }

    @Test func relaunchStartsTheStateOverAndKeepsTheDevice() async throws {
      let (text, status) = try await run(
        "device permission camera granted; device network offline; device push ping; expect pings=1 online=no; "
          + "unlock; expect prompt=biometry; device relaunch; expect pings=0 prompt=none online=no phase=none; "
          + "camera; expect camera=granted"
      )
      #expect(status == .ok, "\(text)")
    }

    @Test func relaunchCancelsTheOldStoresTimers() async throws {
      try await serially {
        let host = TinyAppConfig.headless(device: AgentDeviceConfig(relaunch: true))
        let runner = host.makeRunner()
        _ = await runner.launch()
        let result = try await runner.run("open 2; save; expect pending=1; device relaunch; expect screen=items pending=0")
        #expect(result.status == .ok, "\(StepFormatter.text(result.steps))")
        #expect(
          StepFormatter.text(result.steps[3]) == """
            > device relaunch
              screen=items items=3 loading=false calls=items.fetch
            """
        )
      }
    }

    @Test func theJSONFormCarriesAPromptOnlyWhenOneIsPending() async throws {
      let steps = try await serially {
        let runner = Gadget.host().makeRunner()
        _ = await runner.launch()
        return try await runner.run("camera; device prompt allow").steps
      }
      let json = StepFormatter.json(steps)
      #expect(json.components(separatedBy: "\"prompt\" : \"camera\"").count == 2)
      #expect(json.components(separatedBy: "\"prompt\"").count == 2)
    }

    @Test func docsListTheConfiguredSubcommands() {
      let docs = AgentRegistry.runtimeCommands(device: Gadget.device.surface).map(\.usage)
      #expect(
        docs == [
          "expect k=v [k=v …]", "advance <duration>", "mock <client.method> <error>", "wait [<duration>] [k=v …]",
          "device permission <service> <not-determined|granted|denied|limited>", "device prompt <allow|deny|limited>",
          "device open-url <url>", "device push <name> [tap]", "device background", "device foreground",
          "device relaunch", "device network <online|offline>", "device location <lat>,<lon>|none",
          "device biometry <enrolled|unenrolled|match|fail>",
        ]
      )
      #expect(AgentRegistry.runtimeCommands().count == 4)
      #expect(
        AgentRegistry.runtimeCommands(device: Gadget.device.surface)[0].help
          .contains("error=<code|none>, pending=<n> or prompt=<service|none>")
      )
    }

    /// Observers hear a change in the order they subscribed, the same in every process (CONTRACT.md §6), not in
    /// the order of a hash table seeded per process: two refetches when the network comes back must run in one order.
    @Test func observersHearAChangeInTheOrderTheySubscribed() async {
      let device = AgentDevice(driven: true)
      let subscribed = Array(0..<32)
      let online = await hearingOrder(count: subscribed.count, subscribe: device.onlineUpdates) {
        device.setOnline(false)
      } heard: { !$0 }
      #expect(online == subscribed)
      let location = await hearingOrder(count: subscribed.count, subscribe: device.locationUpdates) {
        device.setLocation(.init(latitude: 52.2297, longitude: 21.0122))
      } heard: { $0 != nil }
      #expect(location == subscribed)
    }

    /// The order in which `count` observers, each subscribed by `subscribe` one after another, hear `change`.
    func hearingOrder<Value: Sendable>(
      count: Int, subscribe: () -> AsyncStream<Value>, change: () -> Void, heard: @escaping @MainActor (Value) -> Bool
    ) async -> [Int] {
      await serially {
        let order = HearingOrder()
        let observers = (0..<count).map { index in
          let updates = subscribe()
          return Task { @MainActor in
            for await value in updates where heard(value) {
              order.indices.append(index)
              return
            }
          }
        }
        await Task.megaYield()
        change()
        for observer in observers { await observer.value }
        return order.indices
      }
    }

    @Test func theCoverageGuardNamesUnusedDeviceCommands() throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: "agentctl-device-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      try "device push ping tap\ndevice network offline\nexpect online=no\n"
        .write(to: directory.appending(path: "a.appctl"), atomically: true, encoding: .utf8)
      let coverage = try AgentCoverage(screens: Gadget.registry, scenarios: directory) { Gadget.host().makeRunner() }
      #expect(
        try coverage.unusedDeviceCommands() == [
          "device permission", "device prompt", "device open-url", "device background", "device foreground",
          "device relaunch", "device location", "device biometry",
        ]
      )
    }
  }
}
