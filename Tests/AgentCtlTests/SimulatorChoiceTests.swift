#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: `--sim` (or the config's simulator) given by name never picks silently among simulators of
    /// that name. One booted match wins; several booted, or several on the runtime it would take, is a usage error
    /// (exit 2) listing their UDIDs; matches on different runtimes only take the newest released runtime and say so.
    ///
    /// A fake `simctl list` plays the simulators, as `xcrun simctl list … -j` prints them.
    @MainActor
    @Suite struct SimulatorChoiceTests {
      /// A simulator for the fake list: its UDID's last digits, name, runtime and state.
      struct Fake {
        var id: Int
        var name = "iPhone 16 Pro"
        var runtime: String
        var booted = false
        var udid: String { String(format: "5C0A5A2E-0000-4000-8000-%012d", id) }
      }

      /// Resolves `name` against a fake `simctl list` of `devices`; iOS 27.0 is a beta runtime.
      func resolve(_ name: String, _ devices: [Fake], runtimeMajor: Int? = nil) throws -> Simulator.Device {
        let directory = try CLICommandTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var byRuntime: [String: [[String: String]]] = [:]
        for device in devices {
          let key = "com.apple.CoreSimulator.SimRuntime.iOS-" + device.runtime.replacingOccurrences(of: ".", with: "-")
          byRuntime[key, default: []].append(
            ["udid": device.udid, "name": device.name, "state": device.booted ? "Booted" : "Shutdown"]
          )
        }
        let list = try JSONSerialization.data(withJSONObject: ["devices": byRuntime])
        try list.write(to: directory.appending(path: "devices.json"))
        let runtimes = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","buildversion":"25A5212f"}]}"#
        try runtimes.write(to: directory.appending(path: "runtimes.json"), atomically: true, encoding: .utf8)
        let tool = directory.appending(path: "simctl")
        try """
        #!/bin/bash
        dir="$(cd "$(dirname "$0")" && pwd)"
        case "$1 $2" in
          "list runtimes") cat "$dir/runtimes.json" ;;
          "list devices") cat "$dir/devices.json" ;;
        esac
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return try Simulator.$simctl.withValue([tool.path]) {
          try Simulator(root: directory).resolve(name, runtimeMajor: runtimeMajor)
        }
      }

      /// The note `choose` would print, for the same devices.
      func note(_ name: String, _ devices: [Simulator.Device]) throws -> String? {
        try Simulator.choose(name, among: devices, runtimeMajor: nil).note
      }

      @Test func aUDIDOrTheOnlyOneOfThatNameIsTaken() throws {
        let devices = [Fake(id: 1, runtime: "26.5"), Fake(id: 2, runtime: "18.6"), Fake(id: 3, name: "iPad", runtime: "26.5")]
        #expect(try resolve(devices[1].udid, devices).udid == devices[1].udid)
        #expect(try resolve("iPad", devices).udid == devices[2].udid)
      }

      @Test func ofSeveralTheBootedOneWins() throws {
        let devices = [Fake(id: 1, runtime: "26.5"), Fake(id: 2, runtime: "18.6", booted: true), Fake(id: 3, runtime: "26.5")]
        #expect(try resolve("iPhone 16 Pro", devices).udid == devices[1].udid)
      }

      @Test func severalBootedIsAUsageError() throws {
        AgentCtl.install(StubRuntime())
        let devices = [
          Fake(id: 1, runtime: "26.5", booted: true), Fake(id: 2, runtime: "18.6", booted: true), Fake(id: 3, runtime: "26.5"),
        ]
        let error = #expect(throws: UsageError.self) { try resolve("iPhone 16 Pro", devices) }
        #expect(
          error?.description == """
            several simulators are named 'iPhone 16 Pro'; pass --sim <UDID>:
              5C0A5A2E-0000-4000-8000-000000000001  iPhone 16 Pro (iOS 26.5)
              5C0A5A2E-0000-4000-8000-000000000002  iPhone 16 Pro (iOS 18.6)
            """
        )
        #expect(AppCommands.fail(error!) == 2)
      }

      /// Xcode's one-per-runtime simulators: the newest released runtime (not the beta), and a note saying so.
      @Test func onDifferentRuntimesTheNewestReleasedIsTakenWithANote() throws {
        let devices = [Fake(id: 1, runtime: "18.6"), Fake(id: 2, runtime: "27.0"), Fake(id: 3, runtime: "26.5")]
        let device = try resolve("iPhone 16 Pro", devices)
        #expect(device.udid == devices[2].udid)
        #expect(
          try note("iPhone 16 Pro", [device, device.with(udid: "B", runtime: "iOS 18.6", version: [18, 6])])
            == "note: 2 simulators are named 'iPhone 16 Pro'; using iPhone 16 Pro (iOS 26.5) "
            + "[5C0A5A2E-0000-4000-8000-000000000003], the newest runtime; pass --sim <UDID> to choose"
        )
      }

      /// Clones on the runtime it would take: nothing tells them apart.
      @Test func twoOnTheRuntimeItWouldTakeIsAUsageError() throws {
        AgentCtl.install(StubRuntime())
        let devices = [Fake(id: 1, runtime: "26.5"), Fake(id: 2, runtime: "18.6"), Fake(id: 3, runtime: "26.5")]
        let error = #expect(throws: UsageError.self) { try resolve("iPhone 16 Pro", devices) }
        #expect(
          error?.description == """
            several simulators are named 'iPhone 16 Pro'; pass --sim <UDID>:
              5C0A5A2E-0000-4000-8000-000000000001  iPhone 16 Pro (iOS 26.5)
              5C0A5A2E-0000-4000-8000-000000000003  iPhone 16 Pro (iOS 26.5)
            """
        )
      }

      /// A runtime filter (`check --ui`'s snapshot simulator) narrows the matches first, and names itself if they are
      /// still ambiguous.
      @Test func aRuntimeFilterNarrowsTheChoice() throws {
        let devices = [Fake(id: 1, runtime: "26.5"), Fake(id: 2, runtime: "18.6"), Fake(id: 3, runtime: "26.5")]
        #expect(try resolve("iPhone 16 Pro", devices, runtimeMajor: 18).udid == devices[1].udid)
        let error = #expect(throws: UsageError.self) { try resolve("iPhone 16 Pro", devices, runtimeMajor: 26) }
        #expect(error?.description.hasPrefix("several simulators are named 'iPhone 16 Pro' on iOS 26; pass --sim <UDID>:") == true)
      }

      @Test func noMatchNamesTheAvailableOnes() throws {
        let error = #expect(throws: AppCtlError.self) { try resolve("iPhone 99", [Fake(id: 1, runtime: "26.5")]) }
        #expect("\(error.map { "\($0)" } ?? "")" == "no available simulator named 'iPhone 99'. Available: iPhone 16 Pro")
      }
    }
  }

  extension Simulator.Device {
    fileprivate func with(udid: String, runtime: String, version: [Int]) -> Self {
      var copy = self
      copy.udid = udid
      copy.runtime = runtime
      copy.version = version
      return copy
    }
  }
#endif
