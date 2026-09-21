import AgentCtlCore
import AgentCtlTCA
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards: `POST /run`'s two forms carry the same information. A script that does not parse fails
  /// with no step to put the reason in; the text form has always appended it, and the JSON form must not drop it.
  /// The router is driven directly, on a headless runner — no server, no network. (The bridge's HTTP layer is
  /// covered in `BridgeTests`.)
  @MainActor
  @Suite struct BridgeRouterTests {
    func post(_ script: String, json: Bool) async -> BridgeResponse {
      await serially {
        let runner = TinyAppConfig.headless().makeRunner()
        _ = await runner.launch()
        let router = BridgeRouter(runner: runner, screensText: { "" })
        return await router.handle(
          BridgeRequest(method: "POST", path: "/run", query: json ? ["format": "json"] : [:], body: script)
        )
      }
    }

    @Test func aParseErrorKeepsItsReasonInTheJSONForm() async throws {
      let response = await post("expect \"open", json: true)
      #expect(response.exitCode == 2)
      #expect(response.contentType == "application/json")
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any], "\(response.body)"
      )
      #expect(object["error"] as? String == "parse error: line 1, column 8: unterminated quote")
      #expect((object["steps"] as? [Any])?.isEmpty == true)
    }

    /// The text form is byte-for-byte what it was: the line the CLI prints to stderr, as the body.
    @Test func aParseErrorInTheTextFormIsUnchanged() async {
      let response = await post("expect \"open", json: false)
      #expect(response.exitCode == 2)
      #expect(response.body == "error: parse error: line 1, column 8: unterminated quote\n")
    }

    /// A run that has steps, passing or failing, is still the plain array — the same JSON `run --json` prints.
    @Test func aRunWithStepsIsStillAnArray() async throws {
      for (script, exit) in [("expect screen=items", Int32(0)), ("expect screen=nope", 1)] {
        let response = await post(script, json: true)
        #expect(response.exitCode == exit)
        let steps = try #require(
          try JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [[String: Any]], "\(response.body)"
        )
        #expect(steps.count == 1)
        #expect(steps[0]["ok"] as? Bool == (exit == 0))
      }
    }
  }
}
