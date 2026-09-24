// The bridge is `#if DEBUG` from end to end, so its tests are too: in a release build there is nothing to test.
#if DEBUG
  @testable import AgentCtlBridge
  import AgentCtlCore
  import AgentCtlTCA
  import ComposableArchitecture
  import Foundation
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

      /// A live app with zero latency whose runner synthesizes appearance (there are no views in a test).
      func startBridge() async throws -> Bridge {
        let app = TinyAppConfig.live(latency: .zero)
        let runner = app.makeRunner(synthesizesAppearance: true)
        _ = await runner.launch()
        let router = BridgeRouter(runner: runner, screensText: { ScreensRenderer.render(TinyAppConfig.screens, mockExample: TinyAppConfig.docsText.mockExample) })
        let server = BridgeServer { await router.handle($0) }
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
        let headless = await serially {
          let runner = TinyAppConfig.headless().makeRunner()
          _ = await runner.launch()
          return StepFormatter.text(await runner.run(script).steps) + "\n"
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
      }

      /// A launch seed is a script, so a launch that never settles fails it before its first command — and the
      /// app's log says so, rather than printing the steps as if the seed had been applied.
      @Test func aSeedStopsWhenTheLaunchDoesNotSettle() async {
        let seed = await serially {
          await AgentLaunch<Restless>.applySeed("expect screen=restless", with: Restless.makeRunner())
        }
        #expect(seed.status == .failed)
        #expect(seed.log.hasPrefix("AgentCtlBridge: seed FAILED (exit 1)\n> (launch)"), "\(seed.log)")
        #expect(seed.log.contains("settled=false"))
        #expect(!seed.log.contains("> expect"), "the seed ran on a launch that did not settle:\n\(seed.log)")
      }

      @Test func aSeedRunsAfterASettledLaunch() async {
        let applied = await AgentLaunch<TinyRoot>.applySeed(
          "open 2", with: TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
        )
        #expect(applied.status == .ok)
        #expect(applied.log.hasPrefix("AgentCtlBridge: seed applied\n> (launch)"), "\(applied.log)")
        #expect(applied.log.contains("> open 2\n  screen=items/2"))
        // A seed that does not parse fails with its reason, as `run` does.
        let unparsed = await AgentLaunch<TinyRoot>.applySeed(
          "open \"2", with: TinyAppConfig.live(latency: .zero).makeRunner(synthesizesAppearance: true)
        )
        #expect(unparsed.status == .usage)
        #expect(unparsed.log.hasSuffix("error: parse error: line 1, column 6: unterminated quote"), "\(unparsed.log)")
      }

      @Test func launchArguments() {
        let options = AgentLaunch<TinyRoot>.Options(arguments: [
          "TinyApp", "-agent-port", "9000", "-appctl-seed", "open 2; save", "-mock-latency", "0",
          "-clear-session",
        ])
        #expect(options.port == 9000)
        #expect(options.seed == "open 2; save")
        #expect(options.latency == .zero)
        #expect(options.clearSession)
        #expect(AgentLaunch<TinyRoot>.Options(arguments: ["TinyApp"]) == AgentLaunch<TinyRoot>.Options(arguments: []))
        // With no `-agent-port`, the app listens where the CLI connects by default.
        #expect(AgentLaunch<TinyRoot>.Options(arguments: []).port == BridgeDefaults.port)
      }
    }
  }
#endif
