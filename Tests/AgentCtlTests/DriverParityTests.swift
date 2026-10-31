import AgentCtlCore
import AgentCtlTCA
import Foundation
import Testing
import TinyApp

extension AgentCtlSuite {
  /// What this guards, with TinyMVVM's own tests: the engine is architecture-neutral. TinyApp (TCA,
  /// `AgentStoreDriver`) and TinyMVVM (MVVM-C, `AgentObservationDriver`) are the same app, and every script prints the
  /// same bytes and exits the same way on both: TinyApp's scenarios, failures of every kind, `advance`, `mock`,
  /// `device` and a relaunch.
  ///
  /// TinyMVVM is its own package (`Examples/TinyMVVM`), because Swift's `@Observable` needs iOS 17 and this package
  /// supports iOS 16. So the two cannot run side by side in one test: this one keeps TinyApp's transcripts current
  /// in TinyMVVM's fixture, and TinyMVVM's `ParityTests` run the same scripts and compare.
  /// `APPCTL_RECORD=1 swift test --filter DriverParityTests` rewrites the fixture.
  @MainActor
  struct DriverParityTests {
    static let fixture = PackageRoot.url.appending(
      path: "Examples/TinyMVVM/Tests/TinyMVVMTests/Fixtures/tinyapp-transcripts.json"
    )

    static let scripts: [String] = {
      let scenarios = ScenarioRunner.files(in: PackageRoot.scenarios).compactMap {
        try? String(contentsOf: $0, encoding: .utf8)
      }
      return scenarios + [
        "open 2; save; advance 1m",
        "open 2; save; back",
        "back",
        "mock items.fetch timeout; refresh; retry",
        "mock items.fetch bogus",
        "open x",
        "open 9; expect error=notFound; open 1",
        "open 1; device push item-updated; device push item-updated tap",
        "retry",
        "open 2; save; open 1",
        "open 2; save; save; expect error=cooldown; advance 1s; expect cooldown=2",
        "device open-url tinyapp://items/3; device open-url tinyapp://items/x",
        "device relaunch",
      ]
    }()

    /// A relaunch throws the app away mid-countdown and after a failure, and both drivers start over alike.
    static let relaunchScript = "open 2; save; expect pending=1; device relaunch; expect screen=items pending=0; "
      + "mock items.fetch network; device relaunch; expect error=network; device relaunch; open 3"

    func run<Driver: AgentDriver>(_ runner: ScriptRunner<Driver>, _ script: String) async throws -> String {
      let launch = await runner.launch()
      let result = try await runner.run(script)
      return StepFormatter.text([launch.step] + result.steps) + "\nexit=\(result.status.rawValue)"
    }

    @Test func tinyMVVMsFixtureHoldsWhatTinyAppPrints() async throws {
      #expect(Self.scripts.count >= 18)
      var transcripts: [Transcript] = []
      for script in Self.scripts {
        let output = try await serially { try await run(TinyAppConfig.headless().makeRunner(), script) }
        transcripts.append(Transcript(script: script, relaunch: false, output: output))
      }
      let relaunch = try await serially {
        try await run(TinyAppConfig.headless(device: AgentDeviceConfig(relaunch: true)).makeRunner(), Self.relaunchScript)
      }
      #expect(relaunch.hasSuffix("exit=0"), "\(relaunch)")
      transcripts.append(Transcript(script: Self.relaunchScript, relaunch: true, output: relaunch))

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let current = try encoder.encode(transcripts) + Data("\n".utf8)
      if ProcessInfo.processInfo.environment["APPCTL_RECORD"] == "1" {
        try current.write(to: Self.fixture)
      }
      let committed = try? Data(contentsOf: Self.fixture)
      #expect(
        committed == current,
        "\(Self.fixture.path) is stale: run `APPCTL_RECORD=1 swift test --filter DriverParityTests` and commit it"
      )
    }
  }

  /// One script's run on TinyApp, as TinyMVVM's `ParityTests` read it back.
  struct Transcript: Codable, Equatable {
    var script: String
    /// Whether the run's device allows `device relaunch`.
    var relaunch: Bool
    var output: String
  }
}
