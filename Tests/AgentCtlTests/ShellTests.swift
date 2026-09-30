#if os(macOS)
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  extension AgentCtlSuite {
    /// What this guards: no tool the CLI runs can hang it. A wedged CoreSimulator makes `simctl` hang instead of
    /// failing; each call has a time limit, the limit applies even while the child's output is being read, and a
    /// child that outlives it is gone afterwards, even one that ignores SIGTERM or leaves a grandchild on the pipe.
    @Suite struct ShellTests {
      /// A fake tool: a shell script in a temporary directory, run through `/bin/sh`.
      static func tool(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentctl-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "tool.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        return script
      }

      static func isRunning(_ pattern: String) -> Bool {
        !Shell.capture(["pgrep", "-f", pattern], in: URL(fileURLWithPath: "/"), timeout: 10).isEmpty
      }

      @Test func captureStopsAToolThatNeverExits() throws {
        let marker = "agentctl-never-\(UUID().uuidString)"
        let script = try Self.tool("echo started; exec sleep 1000 # \(marker)\n")
        let start = Date()
        let result = Shell.captureResult(["/bin/sh", script.path, marker], in: script.deletingLastPathComponent(), timeout: 1)
        #expect(!result.finished)
        #expect(Date().timeIntervalSince(start) < 6, "took \(Date().timeIntervalSince(start)) s")
        #expect(!Self.isRunning(marker), "the tool was left running")
      }

      @Test func captureStopsAToolThatIgnoresSIGTERM() throws {
        let marker = "agentctl-stubborn-\(UUID().uuidString)"
        let script = try Self.tool("trap '' TERM\nwhile true; do sleep 1; done # \(marker)\n")
        let start = Date()
        let result = Shell.captureResult(["/bin/sh", script.path, marker], in: script.deletingLastPathComponent(), timeout: 1)
        #expect(!result.finished)
        #expect(Date().timeIntervalSince(start) < 8, "took \(Date().timeIntervalSince(start)) s")
        // The shell is gone; the `sleep 1` it was waiting on ends within a second by itself.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!Self.isRunning("/bin/sh \(script.path)"), "the tool was left running")
      }

      /// A grandchild that inherits the pipe keeps it open after the child exits; the output is not waited for.
      @Test func captureReturnsWhenAGrandchildHoldsThePipe() throws {
        let marker = "agentctl-orphan-\(UUID().uuidString)"
        let script = try Self.tool("echo done\n(exec -a \(marker) sleep 30) &\nexit 0\n")
        let start = Date()
        let result = Shell.captureResult(["/bin/sh", script.path], in: script.deletingLastPathComponent(), timeout: 20)
        #expect(result.finished)
        #expect(Date().timeIntervalSince(start) < 5, "took \(Date().timeIntervalSince(start)) s")
        _ = Shell.capture(["pkill", "-f", marker], in: URL(fileURLWithPath: "/"), timeout: 10)
      }

      @Test func runStopsAToolThatNeverExitsAndSaysSoInItsLog() throws {
        let marker = "agentctl-run-\(UUID().uuidString)"
        let script = try Self.tool("exec sleep 1000 # \(marker)\n")
        let log = script.deletingLastPathComponent().appending(path: "tool.log")
        let start = Date()
        let status = Shell.run(["/bin/sh", script.path, marker], in: script.deletingLastPathComponent(), log: log, timeout: 1)
        #expect(status == Shell.timedOut)
        #expect(Date().timeIntervalSince(start) < 6)
        #expect(!Self.isRunning(marker))
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(text.contains("did not finish within 1 s; stopped it"))
      }

      @Test func aToolThatFinishesInTimeIsUnaffected() throws {
        let script = try Self.tool("echo hello; exit 3\n")
        let result = Shell.captureResult(["/bin/sh", script.path], in: script.deletingLastPathComponent(), timeout: 10)
        #expect(result.finished)
        #expect(result.output == "hello\n")
        let log = script.deletingLastPathComponent().appending(path: "tool.log")
        #expect(Shell.run(["/bin/sh", script.path], in: script.deletingLastPathComponent(), log: log, timeout: 10) == 3)
      }
    }
  }
#endif
