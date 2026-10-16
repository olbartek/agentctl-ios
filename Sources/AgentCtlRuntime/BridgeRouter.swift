// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import AgentCtlCore
  import Foundation

  /// An HTTP request as the agent bridge sees it.
  public struct BridgeRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: String

    public init(method: String, path: String, query: [String: String] = [:], body: String = "") {
      self.method = method
      self.path = path
      self.query = query
      self.body = body
    }
  }

  public struct BridgeResponse: Equatable, Sendable {
    public var status: Int
    public var body: String
    public var contentType: String
    /// The `appctl` exit code for this response, sent as `X-Appctl-Exit`.
    public var exitCode: Int32

    public init(status: Int, body: String, contentType: String = "text/plain; charset=utf-8", exitCode: Int32) {
      self.status = status
      self.body = body
      self.contentType = contentType
      self.exitCode = exitCode
    }
  }

  /// The agent bridge's endpoints (CONTRACT.md §8), independent of the transport so they can be tested on the host:
  ///
  /// - `POST /run` (body: a script; `?format=json` for JSON): the same output as the CLI's `run`, with what `run`
  ///   prints to stderr — a script's parse error — in the body too: after the steps as `error: …` in the text
  ///   form, and as `{"error": …, "steps": […]}` in place of the steps array in the JSON form.
  /// - `GET /state`: the app's whole state (``AgentDriver/stateDump``).
  /// - `GET /screens`: every screen and its commands.
  /// - `GET /snapshot`: the current screen's summary line.
  @MainActor
  public final class BridgeRouter<Driver: AgentDriver> {
    let runner: ScriptRunner<Driver>
    let screensText: @MainActor () -> String

    public init(runner: ScriptRunner<Driver>, screensText: @escaping @MainActor () -> String) {
      self.runner = runner
      self.screensText = screensText
    }

    /// Throws `CancellationError` when a `POST /run` is cancelled, its client having gone away (CONTRACT.md §8.1).
    public func handle(_ request: BridgeRequest) async throws(CancellationError) -> BridgeResponse {
      switch (request.method, request.path) {
      case ("POST", "/run"):
        let result = try await runner.run(request.body)
        if request.query["format"] == "json" {
          return BridgeResponse(
            status: 200,
            body: StepFormatter.json(result.steps, error: result.message),
            contentType: "application/json",
            exitCode: result.status.rawValue
          )
        }
        var body = StepFormatter.text(result.steps)
        if let message = result.message {
          body += (body.isEmpty ? "" : "\n") + "error: \(message)"
        }
        return BridgeResponse(status: 200, body: body + "\n", exitCode: result.status.rawValue)

      case ("GET", "/state"):
        return BridgeResponse(status: 200, body: runner.stateDump + "\n", exitCode: 0)

      case ("GET", "/screens"):
        return BridgeResponse(status: 200, body: screensText() + "\n", exitCode: 0)

      case ("GET", "/snapshot"):
        return BridgeResponse(status: 200, body: StepFormatter.text(runner.snapshot(command: "(snapshot)")) + "\n", exitCode: 0)

      case (_, "/run"), (_, "/state"), (_, "/screens"), (_, "/snapshot"):
        return BridgeResponse(status: 405, body: "method not allowed\n", exitCode: RunStatus.usage.rawValue)

      default:
        return BridgeResponse(
          status: 404,
          body: "not found; endpoints: POST /run, GET /state, GET /screens, GET /snapshot\n",
          exitCode: RunStatus.usage.rawValue
        )
      }
    }
  }
#endif
