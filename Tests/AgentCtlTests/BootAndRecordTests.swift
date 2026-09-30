#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: a shut-down simulator and a recording that left nothing, as agentctl-android handles them. With
    /// `--no-build`, `app launch` and `app test` say once that the simulator is not booted, and touch nothing; with a
    /// build, it is booted first, before a recording starts. `app test --record` never says "recorded" for a missing or
    /// empty video.
    ///
    /// A fake `simctl` plays the simulator: its state lives in a file, `bootstatus` boots it, `launch` fails, and its
    /// recorder writes what the test asks for. Every call is logged, so a test can see what was not done.
    @MainActor
    @Suite struct BootAndRecordTests {
      nonisolated static let udid = "5C0A5A2E-0000-4000-8000-0000000000B7"

      /// A fake `simctl` in a fresh directory, which also serves as the repo root.
      @MainActor
      struct FakeSimctl {
        let directory: URL
        var tool: URL { directory.appending(path: "simctl") }
        var calls: [String] {
          ((try? String(contentsOf: directory.appending(path: "calls.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        }

        /// - Parameter recorder: what `recordVideo` leaves: `nothing`, `empty` (a 0-byte file) or `video` (some bytes).
        init(booted: Bool, recorder: String = "video") throws {
          directory = try CLICommandTests.temporaryDirectory()
          try (booted ? "Booted" : "Shutdown").write(
            to: directory.appending(path: "state"), atomically: true, encoding: .utf8
          )
          try """
          #!/bin/bash
          dir="$(cd "$(dirname "$0")" && pwd)"
          echo "$*" >> "$dir/calls.txt"
          case "$1 $2" in
            "list runtimes") echo '{"runtimes":[]}' ;;
            "list devices")
              printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"\(BootAndRecordTests.udid)",'
              printf '"name":"iPhone 17 Pro","state":"%s"}]}}\\n' "$(cat "$dir/state")" ;;
            "bootstatus "*) echo Booted > "$dir/state" ;;
            "launch "*) echo "An error was encountered processing the command"; exit 1 ;;
            "io "*)
              video="${@: -1}"
              echo "Recording started"
              trap 'case "\(recorder)" in empty) : > "$video" ;; video) echo frames > "$video" ;; esac; exit 0' INT
              while true; do sleep 0.05; done ;;
          esac
          exit 0
          """.write(to: tool, atomically: true, encoding: .utf8)
          try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        func run<T>(_ body: () async throws -> T) async throws -> T {
          try await Simulator.$simctl.withValue([tool.path]) {
            let result = await CLICommandTests.withRepoRoot(directory.path) { () async -> Result<T, any Error> in
              do { return .success(try await body()) } catch { return .failure(error) }
            }
            return try result.get()
          }
        }
      }

      /// A scenario file for `app test`.
      func scenario(in directory: URL) throws -> URL {
        let file = directory.appending(path: "browse.appctl")
        try "expect screen=items\n".write(to: file, atomically: true, encoding: .utf8)
        return file
      }

      func options(build: Bool, record: String? = nil) -> AppTest.Options {
        AppTest.Options(simulator: Self.udid, latency: nil, build: build, port: 8799, record: record, stepDelay: nil)
      }

      @Test func launchWithoutABuildSaysTheSimulatorIsNotBooted() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: false)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let error = try await fake.run {
          await #expect(throws: AppCtlError.self) {
            _ = try await AppCommands.launchApp(
              root: fake.directory, seed: nil, simulator: Self.udid, latency: nil, clearSession: false, build: false,
              port: 8799
            )
          }
        }
        #expect(
          "\(error.map { "\($0)" } ?? "")"
            == "iPhone 17 Pro (iOS 26.5) [\(Self.udid)] is not booted; boot it, or run xctl app launch"
        )
        #expect(!fake.calls.contains { $0.hasPrefix("launch ") || $0.hasPrefix("bootstatus ") }, "\(fake.calls)")
      }

      @Test func appTestWithoutABuildStopsBeforeTheFirstScenarioAndRecordsNothing() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: false)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let file = try scenario(in: fake.directory)
        let video = fake.directory.appending(path: "run.mp4")
        let status = try await fake.run {
          await AppTest.run(paths: [file.path], options: options(build: false, record: video.path))
        }
        #expect(status == 3)
        #expect(!fake.calls.contains { $0.hasPrefix("launch ") || $0.hasPrefix("io ") }, "\(fake.calls)")
      }

      /// With a build, the simulator is booted up front, so a recording started next films it.
      @Test func aBuildBootsTheSimulatorFirst() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: false)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let device = try await fake.run {
          let sim = Simulator(root: fake.directory)
          return try sim.ready(
            sim.resolve(Self.udid), boot: true, log: fake.directory.appending(path: "launch.log")
          )
        }
        #expect(device.isBooted)
        #expect(fake.calls.contains("bootstatus \(Self.udid) -b"), "\(fake.calls)")
      }

      @Test(arguments: ["nothing", "empty"])
      func aRecordingThatLeftNoVideoIsNotReportedAsRecorded(recorder: String) async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: true, recorder: recorder)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let (written, report) = try await fake.run {
          let sim = Simulator(root: fake.directory)
          let recording = try AppTest.Recording.start(
            root: fake.directory, device: try sim.resolve(Self.udid), to: fake.directory.appending(path: "run.mp4")
          )
          let written = recording.stop()
          return (written, recording.report(written: written))
        }
        #expect(!written)
        #expect(report == "warning: nothing was recorded; see .xctl/logs/app-test-record.log")
      }

      @Test func aRecordingThatLeftAVideoIsReported() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: true, recorder: "video")
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let video = fake.directory.appending(path: "run.mp4")
        let (written, report) = try await fake.run {
          let sim = Simulator(root: fake.directory)
          let recording = try AppTest.Recording.start(root: fake.directory, device: try sim.resolve(Self.udid), to: video)
          recording.chapter("browse")
          let written = recording.stop()
          return (written, recording.report(written: written))
        }
        #expect(written)
        #expect(report == "recorded \(video.standardizedFileURL.path(percentEncoded: false)) (chapters: run.mp4.chapters.txt)")
        let chapters = try String(contentsOf: video.appendingPathExtension("chapters.txt"), encoding: .utf8)
        #expect(chapters == "00:00:00 browse\n")
      }

      /// `app test --record` end to end, on a booted simulator where every launch fails: exit 3, and the video it did
      /// not write is not reported.
      @Test func appTestWithARecorderThatWritesNothingExitsThree() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: true, recorder: "nothing")
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let file = try scenario(in: fake.directory)
        let video = fake.directory.appending(path: "run.mp4")
        let status = try await fake.run {
          await AppTest.run(paths: [file.path], options: options(build: false, record: video.path))
        }
        #expect(status == 3)
        #expect(fake.calls.contains { $0.hasPrefix("io \(Self.udid) recordVideo") }, "\(fake.calls)")
        #expect(!FileManager.default.fileExists(atPath: video.path))
      }

      /// Unlike `app record start`'s, `app test`'s recorder does not outlive a hangup: a closed terminal ends the run,
      /// and nothing would be left to stop the recording.
      @Test func appTestsRecorderEndsWithAHangup() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try FakeSimctl(booted: true)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        try await fake.run {
          let sim = Simulator(root: fake.directory)
          let device = try sim.resolve(Self.udid)
          let attached = try sim.startRecording(
            on: device, to: fake.directory.appending(path: "a.mp4"), log: fake.directory.appending(path: "a.log"),
            detached: false
          ) { _ in }
          let detached = try sim.startRecording(
            on: device, to: fake.directory.appending(path: "d.mp4"), log: fake.directory.appending(path: "d.log")
          ) { _ in }
          defer { Shell.stop(detached) }
          kill(attached.processIdentifier, SIGHUP)
          kill(detached.processIdentifier, SIGHUP)
          let deadline = Date().addingTimeInterval(5)
          while attached.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
          #expect(!attached.isRunning)
          #expect(detached.isRunning)
        }
      }

      /// Each `/run` response of `app test` is checked: one from the same app on Android marks the scenario not run.
      @Test func aScenarioAnsweredByAnotherAppIsNotRun() {
        AgentCtl.install(StubRuntime())
        func response(_ app: String?, _ platform: String?) -> BridgeClient.Response {
          BridgeClient.Response(status: 200, body: "> open 1\n", exitCode: 0, identity: BridgeIdentity(app: app, platform: platform))
        }
        #expect(AppTest.foreign(response("com.example.stub", "ios"), port: 8766) == nil)
        let android = AppTest.foreign(response("com.example.stub", "android"), port: 8766)
        #expect(
          android.map { AppTest.Result(name: "browse", outcome: $0).report }
            == "FAIL browse\n  the app's agent bridge on 127.0.0.1:8766 answers as com.example.stub (android), not "
            + "com.example.stub (ios): another app took the port during the run"
        )
        #expect(AppTest.foreign(response("com.example.stub", nil), port: 8766) != nil)
      }

      @Test func theMessages() {
        AgentCtl.install(StubRuntime())
        let device = Simulator.Device(
          udid: "U", name: "iPhone 17 Pro", runtime: "iOS 26.5", version: [26, 5], isBooted: false, isBeta: false
        )
        #expect(
          Message.bootFailed(device, log: URL(fileURLWithPath: "/r/.xctl/logs/app-launch.log"))
            == "iPhone 17 Pro (iOS 26.5) [U] did not boot; log: /r/.xctl/logs/app-launch.log"
        )
        #expect(Message.nothingRecorded == "warning: nothing was recorded; see .xctl/logs/app-test-record.log")
      }
    }
  }
#endif
