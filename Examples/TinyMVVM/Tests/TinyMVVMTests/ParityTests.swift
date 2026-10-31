import AgentCtlCore
import AgentCtlObservation
import AgentCtlRuntime
import Foundation
import Testing
import TinyMVVM

extension TinyMVVMSuite {
  /// What this guards: the engine is architecture-neutral. TinyApp (TCA, `AgentStoreDriver`) and TinyMVVM (MVVM-C,
  /// `AgentObservationDriver`) are the same app, and every script prints the same bytes and exits the same way on both:
  /// TinyApp's scenarios, failures of every kind, `advance`, `mock`, `device` and a relaunch. TinyApp's side is
  /// the fixture, which the root package's `DriverParityTests` keep current.
  @MainActor
  struct ParityTests {
    struct Transcript: Decodable {
      var script: String
      var relaunch: Bool
      var output: String
    }

    func run<Driver: AgentDriver>(_ runner: ScriptRunner<Driver>, _ script: String) async throws -> String {
      let launch = await runner.launch()
      let result = try await runner.run(script)
      return StepFormatter.text([launch.step] + result.steps) + "\nexit=\(result.status.rawValue)"
    }

    @Test func tinyMVVMPrintsWhatTinyAppPrints() async throws {
      let transcripts = try JSONDecoder().decode(
        [Transcript].self, from: Data(contentsOf: PackageRoot.transcripts)
      )
      #expect(transcripts.count >= 19)
      #expect(transcripts.contains { $0.relaunch })
      for transcript in transcripts {
        let device = transcript.relaunch ? AgentDeviceConfig(relaunch: true) : TinyMVVMConfig.device
        let mvvm = try await serially {
          try await run(TinyMVVMConfig.headless(device: device).makeRunner(), transcript.script)
        }
        #expect(
          transcript.output == mvvm, "\(transcript.script)\n--- TCA\n\(transcript.output)\n--- MVVM-C\n\(mvvm)"
        )
      }
    }
  }
}
