#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: the real-OS `app` commands (`permission`, `openurl`, `push`, `location`, `appearance`) run
    /// exactly these simctl invocations on the resolved, booted simulator, and reject a malformed location or a
    /// missing payload before touching it.
    @MainActor
    @Suite struct RealDeviceCommandsTests {
      typealias Fake = BootAndRecordTests.FakeSimctl
      let udid = BootAndRecordTests.udid

      func calls(_ fake: Fake) -> [String] {
        fake.calls.filter { !$0.hasPrefix("list ") }
      }

      @Test func eachCommandRunsItsSimctlInvocation() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try Fake(booted: true)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let payload = fake.directory.appending(path: "payload.json")
        try #"{"aps":{"alert":"Hi"}}"#.write(to: payload, atomically: true, encoding: .utf8)
        let codes = try await fake.run {
          [
            DeviceCommands.permission(.grant, service: "photos", simulator: udid),
            DeviceCommands.permission(.revoke, service: "location", simulator: udid),
            DeviceCommands.permission(.reset, service: "all", simulator: udid),
            DeviceCommands.openURL("myapp://item/2", simulator: udid),
            DeviceCommands.push(payload.path, simulator: udid),
            DeviceCommands.location("52.2297,21.0122", simulator: udid),
            DeviceCommands.location("clear", simulator: udid),
            DeviceCommands.appearance(dark: true, simulator: udid),
            DeviceCommands.appearance(dark: false, simulator: udid),
          ]
        }
        #expect(codes == Array(repeating: 0, count: 9))
        #expect(
          calls(fake) == [
            "privacy \(udid) grant photos com.example.stub",
            "privacy \(udid) revoke location com.example.stub",
            "privacy \(udid) reset all com.example.stub",
            "openurl \(udid) myapp://item/2",
            "push \(udid) com.example.stub \(payload.standardizedFileURL.path(percentEncoded: false))",
            "location \(udid) set 52.2297,21.0122",
            "location \(udid) clear",
            "ui \(udid) appearance dark",
            "ui \(udid) appearance light",
          ]
        )
      }

      @Test func aMalformedLocationOrAMissingPayloadTouchesNothing() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try Fake(booted: true)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let codes = try await fake.run {
          [
            DeviceCommands.location("52.2,", simulator: udid),
            DeviceCommands.location("north", simulator: udid),
            DeviceCommands.push("/no/such/payload.json", simulator: udid),
          ]
        }
        #expect(codes == [2, 2, 3])
        #expect(calls(fake).isEmpty, "\(fake.calls)")
      }

      @Test func aShutDownSimulatorIsReportedNotUsed() async throws {
        AgentCtl.install(StubRuntime())
        let fake = try Fake(booted: false)
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let code = try await fake.run { DeviceCommands.openURL("myapp://x", simulator: udid) }
        #expect(code == 3)
        #expect(calls(fake).isEmpty)
      }
    }
  }
#endif
