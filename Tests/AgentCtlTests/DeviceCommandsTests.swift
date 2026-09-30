#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: the simulator commands' shared forms. `app info` prints one compact JSON line and
    /// `record.json` is written like `bridge.json`, both byte for byte as agentctl-android does; a recorder that is
    /// gone, or a pid now used by another process, is not taken for ours; and the messages name the host's CLI.
    @MainActor
    @Suite struct DeviceCommandsTests {
      @Test func infoIsOneCompactSortedJSONLine() throws {
        let info = AppInfo(
          appId: "com.example.stub", build: "42", device: "5C0A5A2E-0000-4000-8000-000000000001", platform: "ios",
          version: "1.2/beta"
        )
        #expect(
          try info.encoded()
            == #"{"appId":"com.example.stub","build":"42","device":"5C0A5A2E-0000-4000-8000-000000000001","#
            + #""platform":"ios","version":"1.2/beta"}"#
        )
      }

      @Test func theRecordingFileIsWrittenLikeTheLaunchState() throws {
        AgentCtl.install(StubRuntime())
        let state = RecordingState(
          device: "5C0A5A2E-0000-4000-8000-000000000001", file: "/tmp/demo/a.mp4", pid: 4242,
          startedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        #expect(
          try state.encoded() == """
            {
              "device" : "5C0A5A2E-0000-4000-8000-000000000001",
              "file" : "/tmp/demo/a.mp4",
              "pid" : 4242,
              "platform" : "ios",
              "startedAt" : "2026-09-21T14:13:20Z"
            }

            """
        )
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try state.write(in: root)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".xctl/record.json").path))
        #expect(try RecordingState.read(in: root) == state)
      }

      /// A live process that is not a recorder of that file (here, this test process) is not ours; nor is a dead pid.
      @Test func onlyOurOwnRecorderCountsAsRunning() {
        let mine = RecordingState(
          device: "x", file: "/no/such/recording-\(UUID().uuidString).mp4", pid: Int(getpid()), startedAt: Date()
        )
        #expect(!RecordingState.isRunning(mine))
        let dead = RecordingState(device: "x", file: "/tmp/a.mp4", pid: 999_999, startedAt: Date())
        #expect(!RecordingState.isRunning(dead))
      }

      @Test func stoppingWithNothingRecordingExitsThree() async throws {
        AgentCtl.install(StubRuntime())
        let root = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let none = await CLICommandTests.withRepoRoot(root.path) { DeviceCommands.recordStop() }
        #expect(none == 3)
        let gone = RecordingState(device: "x", file: "/tmp/gone.mp4", pid: 999_999, startedAt: Date())
        try gone.write(in: root)
        let stale = await CLICommandTests.withRepoRoot(root.path) { DeviceCommands.recordStop() }
        #expect(stale == 3)
        #expect(try RecordingState.read(in: root) == nil, "a stale record.json is removed")
      }

      @Test func theMessagesNameTheHostsCLI() {
        AgentCtl.install(StubRuntime())
        let state = RecordingState(device: "x", file: "/tmp/a.mp4", pid: 1, startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(
          Message.recordingRunning(state)
            == "a recording is already running: /tmp/a.mp4 (started 2026-09-21T14:13:20Z); stop it with xctl app record stop"
        )
        #expect(Message.noRecording == "no recording to stop (no .xctl/record.json)")
        #expect(Message.recordingGone(state) == "the recording of /tmp/a.mp4 is no longer running")
        let device = Simulator.Device(
          udid: "U", name: "iPhone 17 Pro", runtime: "iOS 26.5", version: [26, 5], isBooted: true, isBeta: false
        )
        #expect(
          Message.recorderDidNotFinish(state)
            == "the recorder of /tmp/a.mp4 did not finish within 30 s; try xctl app record stop again"
        )
        #expect(
          Message.recordingNotWritten(state) == "the recording /tmp/a.mp4 was not written; see .xctl/logs/app-record.log"
        )
        #expect(Message.notBooted(device) == "iPhone 17 Pro (iOS 26.5) [U] is not booted; boot it, or run xctl app launch")
        #expect(
          Message.notInstalled(on: device)
            == "com.example.stub is not installed on iPhone 17 Pro (iOS 26.5) [U]; run xctl app launch"
        )
      }
    }
  }
#endif
