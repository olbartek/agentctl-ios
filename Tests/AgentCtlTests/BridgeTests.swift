// The bridge is `#if DEBUG` from end to end, so its tests are too: in a release build there is nothing to test.
#if DEBUG
  @testable import AgentCtlBridge
  import AgentCtlCore
  import AgentCtlTCA
  import ComposableArchitecture
  import Foundation
  import Network
  import Testing
  import TinyApp

  extension AgentCtlSuite {
    /// What this guards: the in-app bridge. The HTTP layer is exercised on the host (it builds on macOS too),
    /// against a live store of the example app, and the central claim is the first test's: the same script
    /// produces the same steps through the bridge as it does headlessly.
    @MainActor
    @Suite struct BridgeTests {
      struct Bridge {
        let server: BridgeServer
        let port: UInt16
      }

      static let token = BridgeConnectionsTests.token

      /// A live app with zero latency whose runner synthesizes appearance (there are no views in a test).
      func startBridge() async throws -> Bridge {
        let app = TinyAppConfig.live(latency: .zero)
        let runner = app.makeRunner(synthesizesAppearance: true)
        _ = await runner.launch()
        let router = BridgeRouter(runner: runner, screensText: { ScreensRenderer.render(TinyAppConfig.screens, mockExample: TinyAppConfig.docsText.mockExample) })
        let server = BridgeServer(token: Self.token) { try await router.handle($0) }
        let port = try await server.start(port: 0)
        return Bridge(server: server, port: port)
      }

      func request(
        _ method: String,
        _ path: String,
        body: String = "",
        port: UInt16
      ) async throws -> (status: Int, body: String, exit: String?) {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = Data(body.utf8) }
        request.setValue(Self.token, forHTTPHeaderField: "X-Appctl-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "X-Appctl-Exit"))
      }

      /// The claim this suite exists for: a script produces the same steps through the bridge as it does
      /// headlessly.
      ///
      /// The script must not start anything that waits on the clock. The headless run is on a `TestClock` and
      /// the live run is on real time, so a countdown would print the same number in both only while no tick has
      /// fired yet — a race between a 250 ms settle plus an HTTP round-trip and a 1-second tick, which a loaded
      /// machine loses. `save` is therefore covered by ``poppingTheScreenCancelsTheCountdown`` below, which
      /// asserts the effect rather than the bytes. Do not merge the two back together.
      @Test func runReturnsTheSameStepsAsTheHeadlessRunner() async throws {
        let script = "open 2; back"
        let headless = try await serially {
          let runner = TinyAppConfig.headless().makeRunner()
          _ = await runner.launch()
          return StepFormatter.text(try await runner.run(script).steps) + "\n"
        }
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        let response = try await request("POST", "/run", body: script, port: bridge.port)
        #expect(response.status == 200)
        #expect(response.exit == "0")
        #expect(response.body == headless)
      }

      /// The `save` half of the script above, asserted in a way that real time cannot upset: `pending=1` holds
      /// for the whole three-second cooldown, and popping the screen cancels the effect, after which no step
      /// prints `pending` at all. Neither assertion depends on how far the countdown has got.
      @Test func poppingTheScreenCancelsTheCountdown() async throws {
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        let saved = try await request("POST", "/run", body: "open 2; save", port: bridge.port)
        #expect(saved.exit == "0")
        #expect(saved.body.contains("screen=items/2"))
        #expect(saved.body.contains("saved=true"))
        #expect(saved.body.contains("pending=1"))
        let popped = try await request("POST", "/run", body: "back", port: bridge.port)
        #expect(popped.exit == "0")
        #expect(popped.body.contains("screen=items"))
        #expect(!popped.body.contains("pending="), "the countdown outlived the screen: \(popped.body)")
      }

      @Test func exitCodesTravelInAHeader() async throws {
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        #expect(try await request("POST", "/run", body: "expect screen=items", port: bridge.port).exit == "0")
        #expect(try await request("POST", "/run", body: "expect screen=nope", port: bridge.port).exit == "1")
        #expect(try await request("POST", "/run", body: "expect \"open", port: bridge.port).exit == "2")
        let advance = try await request("POST", "/run", body: "advance 1x", port: bridge.port)
        #expect(advance.exit == "2")
        #expect(advance.body.contains("advance needs a duration"))
      }

      /// `advance` in the running app: the three-second cooldown `save` starts is over after `advance 3s`, every
      /// tick fired, whatever real time did meanwhile (a tick that fired on its own just leaves fewer to advance).
      @Test func advanceMovesTheRunningAppsClock() async throws {
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        let response = try await request(
          "POST", "/run", body: "open 2; save; advance 3s; expect cooldown=0 pending=0", port: bridge.port
        )
        #expect(response.exit == "0", "\(response.body)")
      }

      /// `wait` in the running app takes real time, and reports a state only once the app has settled on it: the
      /// cooldown's first tick, a second after `save`, is the change a bare `wait` sees (CONTRACT.md §2.5, §8.5).
      @Test func waitWaitsInRealTime() async throws {
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        let clock = ContinuousClock()
        let start = clock.now
        let match = try await request("POST", "/run", body: "open 2; save; wait 5s cooldown=2", port: bridge.port)
        #expect(match.exit == "0", "\(match.body)")
        #expect(start.duration(to: clock.now) >= .milliseconds(700))
        let change = try await request("POST", "/run", body: "wait 5s", port: bridge.port)
        #expect(change.exit == "0", "\(change.body)")
        #expect(change.body.contains("cooldown=1"), "\(change.body)")
        let timeout = try await request("POST", "/run", body: "wait 300ms screen=nowhere", port: bridge.port)
        #expect(timeout.exit == "1")
        #expect(timeout.body.hasSuffix("  FAIL wait timed out after 300ms\n  FAIL expected screen=nowhere, got screen=items/2\n"), "\(timeout.body)")
      }

      @Test func otherEndpoints() async throws {
        let bridge = try await startBridge()
        defer { bridge.server.stop() }
        let json = try await request("POST", "/run?format=json", body: "expect screen=items", port: bridge.port)
        #expect(json.body.contains("\"screen\" : \"items\""))
        #expect(try await request("GET", "/state", port: bridge.port).body.contains("TinyRoot.State"))
        #expect(try await request("GET", "/screens", port: bridge.port).body.contains("items/<id>"))
        #expect(try await request("GET", "/snapshot", port: bridge.port).body.contains("screen=items"))
        #expect(try await request("GET", "/nope", port: bridge.port).status == 404)
        #expect(try await request("GET", "/run", port: bridge.port).status == 405)
      }

      @Test func httpParsing() {
        let request = "POST /run?format=json HTTP/1.1\r\nHost: x\r\nContent-Length: 6\r\n\r\nsubmit"
        #expect(
          HTTPParser.parse(Data(request.utf8))
            == .request(BridgeRequest(method: "POST", path: "/run", query: ["format": "json"], body: "submit"))
        )
        #expect(HTTPParser.parse(Data("POST /run HTTP/1.1\r\nContent-Length: 6\r\n\r\nsub".utf8)) == .incomplete)
        #expect(HTTPParser.parse(Data("GET /state HTTP/1.1\r\n".utf8)) == .incomplete)
        #expect(HTTPParser.parse(Data("GARBAGE\r\n\r\n".utf8)) == .malformed)
        #expect(HTTPParser.parse(Data("GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .malformed)
        let response = String(
          decoding: HTTPParser.serialize(BridgeResponse(status: 200, body: "ok", exitCode: 1)), as: UTF8.self
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("X-Appctl-Exit: 1\r\n"))
        #expect(response.hasSuffix("\r\n\r\nok"))
        let named = String(
          decoding: HTTPParser.serialize(BridgeResponse(status: 200, body: "ok", exitCode: 1), app: "com.example.app"),
          as: UTF8.self
        )
        #expect(
          named.contains("X-Appctl-Exit: 1\r\nX-Appctl-App: com.example.app\r\nX-Appctl-Platform: ios\r\nConnection: close\r\n")
        )
      }

      /// Every response names the app, errors included, so a CLI can tell its own app from another one on the port.
      @Test func everyResponseNamesTheApp() async throws {
        let server = BridgeServer(app: "com.example.tinyapp", token: Self.token) { request in
          BridgeResponse(status: request.path == "/snapshot" ? 200 : 404, body: "x\n", exitCode: 0)
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        for path in ["/snapshot", "/nowhere"] {
          var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(path)")))
          request.httpMethod = "GET"
          request.setValue(Self.token, forHTTPHeaderField: "X-Appctl-Token")
          let (_, response) = try await URLSession.shared.data(for: request)
          let http = try #require(response as? HTTPURLResponse)
          #expect(http.value(forHTTPHeaderField: "X-Appctl-App") == "com.example.tinyapp", "\(path)")
          #expect(http.value(forHTTPHeaderField: "X-Appctl-Platform") == "ios", "\(path)")
        }
        let malformed = try await Self.rawRequest("GARBAGE\r\n\r\n", port: port)
        #expect(malformed.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        #expect(malformed.contains("\r\nX-Appctl-App: com.example.tinyapp\r\nX-Appctl-Platform: ios\r\n"))
      }

      /// The bridge does not share a port: with another listener on it, it fails to start instead of binding beside
      /// it (CONTRACT.md §8.1). A CLI that reaches the port then reaches the other listener, which is why launches
      /// check `X-Appctl-App`.
      @Test func theBridgeDoesNotBindAPortSomethingElseListensOn() async throws {
        let first = BridgeServer(app: "first", token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        let port = try await first.start(port: 0)
        defer { first.stop() }
        let second = BridgeServer(app: "second", token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        await #expect(throws: (any Error).self) { _ = try await second.start(port: port) }
        second.stop()
      }

      /// Sends raw bytes and returns the raw response, for requests `URLSession` will not send.
      static func rawRequest(_ bytes: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
          let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
          connection.start(queue: .main)
          connection.send(content: Data(bytes.utf8), completion: .contentProcessed { _ in })
          connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            connection.cancel()
            if let error { continuation.resume(throwing: error) } else {
              continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
            }
          }
        }
      }

      /// A launch seed is a script, so a launch that never settles fails it before its first command — and the
      /// app's log says so, rather than printing the steps as if the seed had been applied.
      @Test func aSeedStopsWhenTheLaunchDoesNotSettle() async throws {
        let seed = try await serially {
          try await AgentLaunch<AgentStoreDriver<Restless>>.applySeed("expect screen=restless", with: Restless.makeRunner())
        }
        #expect(seed.status == .failed)
        #expect(seed.log.hasPrefix("AgentCtlBridge: seed FAILED (exit 1)\n> (launch)"), "\(seed.log)")
        #expect(seed.log.contains("settled=false"))
        #expect(!seed.log.contains("> expect"), "the seed ran on a launch that did not settle:\n\(seed.log)")
      }

      @Test func aSeedRunsAfterASettledLaunch() async throws {
        let applied = try await AgentLaunch<AgentStoreDriver<TinyRoot>>.applySeed(
          "open 2", with: TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
        )
        #expect(applied.status == .ok)
        #expect(applied.log.hasPrefix("AgentCtlBridge: seed applied\n> (launch)"), "\(applied.log)")
        #expect(applied.log.contains("> open 2\n  screen=items/2"))
        // A seed that does not parse fails with its reason, as `run` does.
        let unparsed = try await AgentLaunch<AgentStoreDriver<TinyRoot>>.applySeed(
          "open \"2", with: TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
        )
        #expect(unparsed.status == .usage)
        #expect(unparsed.log.hasSuffix("error: parse error: line 1, column 6: unterminated quote"), "\(unparsed.log)")
      }

      @Test func launchArguments() {
        let options = AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: [
          "TinyApp", "-agent-token", Self.token, "-agent-port", "9000", "-appctl-seed", "open 2; save", "-mock-latency", "0",
          "-clear-session",
        ])
        #expect(options.token == Self.token)
        #expect(options.port == 9000)
        #expect(options.seed == "open 2; save")
        #expect(options.latency == .zero)
        #expect(options.clearSession)
        #expect(AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: ["TinyApp"]) == AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: []))
        // With no `-agent-port`, the app listens where the CLI connects by default.
        #expect(AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: []).port == BridgeDefaults.port)
        #expect(
          AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: ["TinyApp", "-agent-token", Self.token]).port
            == BridgeDefaults.port
        )
      }

      /// Without a well-formed `-agent-token`, every other bridge argument is ignored: a launch without one does not
      /// seed the app, clear its session or pick its port (CONTRACT.md §8.2).
      @Test func withoutATokenEveryLaunchArgumentIsIgnored() {
        typealias Options = AgentLaunch<AgentStoreDriver<TinyRoot>>.Options
        let rest = ["-agent-port", "9000", "-appctl-seed", "open 2; save", "-mock-latency", "0", "-clear-session"]
        let plain = Options(arguments: ["TinyApp"])
        #expect(plain.token == nil && plain.port == BridgeDefaults.port && plain.seed == nil && plain.latency == nil)
        #expect(!plain.clearSession)
        let malformed = [
          [], ["-agent-token"], ["-agent-token", ""], ["-agent-token", String(Self.token.dropLast())],
          ["-agent-token", Self.token + "0"], ["-agent-token", Self.token.uppercased()],
          ["-agent-token", "g" + Self.token.dropFirst()], ["-agent-token=\(Self.token)"],
        ]
        for token in malformed {
          #expect(Options(arguments: ["TinyApp"] + token + rest) == plain, "\(token)")
        }
        // The executable's own name is not an argument.
        #expect(Options(arguments: ["-agent-token", Self.token]) == plain)
      }

      /// The token is never printed or dumped: not in the launch options, not in the server, not in the launch.
      @Test func theTokenIsNeverPrinted() async throws {
        let options = AgentLaunch<AgentStoreDriver<TinyRoot>>.Options(arguments: ["TinyApp", "-agent-token", Self.token])
        let server = BridgeServer(token: Self.token) { _ in BridgeResponse(status: 200, body: "", exitCode: 0) }
        let launch = AgentLaunch(config: TinyAppConfig.appCtl, arguments: ["TinyApp", "-agent-token", Self.token])
        var texts = ["\(options)", String(reflecting: options), String(reflecting: server)]
        for value in [options as Any, server, launch] {
          var dumped = ""
          dump(value, to: &dumped, maxDepth: 4)
          texts.append(dumped)
        }
        for text in texts {
          #expect(!text.contains(Self.token), "\(text)")
        }
        #expect("\(options)".contains("token: <redacted>"))
      }

      /// Without a token the app starts no bridge: `start()` returns at once and nothing listens.
      @Test func withoutATokenNoBridgeStarts() async throws {
        let config = TinyAppConfig.appCtl
        let launch = AgentLaunch(config: config, arguments: ["TinyApp", "-agent-port", "0", "-appctl-seed", "open 2"])
        #expect(launch.options.token == nil)
        #expect(launch.isReady, "a seed was taken without a token")
        await launch.start()
        #expect(!launch.isListening)
        // With one, the same launch listens.
        let listening = AgentLaunch(config: config, arguments: ["TinyApp", "-agent-token", Self.token, "-agent-port", "0"])
        await listening.start()
        #expect(listening.isListening)
        listening.stop()
      }

      /// TinyApp's config, with `device relaunch` allowed in the live app.
      static var relaunchingConfig: AppCtlConfig<AgentStoreDriver<TinyRoot>> {
        var config = TinyAppConfig.appCtl
        config.makeLive = { latency in
          LiveHost(
            initialState: { TinyRoot.State() }, reducer: { TinyRoot() }, latency: latency,
            mockMethods: TinyAppConfig.mockMethods, device: AgentDeviceConfig(relaunch: true)
          ) { deps, _ in
            deps.itemsClient = .liveValue
          }
        }
        return config
      }

      /// The session is the launch without `@Observable`, for UIKit and iOS 16: its seed calls `onReady` once, and a
      /// `device relaunch` through its bridge calls `onAppChange` with the new app.
      @Test func aSessionReportsItsSeedAndItsRelaunches() async throws {
        let session = AgentLaunchSession(
          config: Self.relaunchingConfig,
          arguments: ["TinyApp", "-agent-token", Self.token, "-agent-port", "0", "-appctl-seed", "open 2", "-mock-latency", "0"]
        )
        var readies = 0
        var apps: [ObjectIdentifier] = []
        session.onReady = { readies += 1 }
        session.onAppChange = { apps.append(ObjectIdentifier($0)) }
        let first = ObjectIdentifier(session.app)
        #expect(!session.isReady, "a seed is pending")
        await session.start()
        defer { session.stop() }
        #expect(session.isReady)
        #expect(readies == 1)
        #expect(session.isListening)
        let port = try #require(session.port)

        let response = try await request("POST", "/run", body: "device relaunch", port: port)
        #expect(response.exit == "0", "\(response.body)")
        #expect(apps == [ObjectIdentifier(session.app)])
        #expect(ObjectIdentifier(session.app) != first)
        #expect(readies == 1, "a relaunch is not a second seed")
      }

      /// `AgentLaunch` is the same session, observed: its `app` and `isReady` follow the session's.
      @Test func agentLaunchFollowsItsSession() async throws {
        let launch = AgentLaunch(
          config: Self.relaunchingConfig,
          arguments: ["TinyApp", "-agent-token", Self.token, "-agent-port", "0", "-appctl-seed", "open 2", "-mock-latency", "0"]
        )
        #expect(!launch.isReady)
        await launch.start()
        defer { launch.stop() }
        #expect(launch.isReady)
        let port = try #require(launch.session.port)
        let before = ObjectIdentifier(launch.app)
        let response = try await request("POST", "/run", body: "device relaunch", port: port)
        #expect(response.exit == "0", "\(response.body)")
        #expect(ObjectIdentifier(launch.app) == ObjectIdentifier(launch.session.app))
        #expect(ObjectIdentifier(launch.app) != before)
      }

      /// Without a token a session starts no bridge, and takes no seed, as `AgentLaunch` does.
      @Test func withoutATokenASessionStartsNoBridge() async throws {
        let session = AgentLaunchSession(
          config: TinyAppConfig.appCtl, arguments: ["TinyApp", "-agent-port", "0", "-appctl-seed", "open 2"]
        )
        #expect(session.options == AgentLaunchOptions(arguments: []))
        #expect(session.isReady)
        await session.start()
        #expect(!session.isListening)
        var dumped = ""
        dump(session, to: &dumped, maxDepth: 4)
        let listening = AgentLaunchSession(config: TinyAppConfig.appCtl, arguments: ["TinyApp", "-agent-token", Self.token])
        dump(listening, to: &dumped, maxDepth: 4)
        #expect(!dumped.contains(Self.token))
      }
    }
  }
#endif
