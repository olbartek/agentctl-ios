#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import Foundation

  /// Runs the tools the CLI drives (`simctl`, `xcodebuild`, `ps`), each with a time limit where one makes sense.
  ///
  /// A wedged CoreSimulator makes `simctl` hang rather than fail, and one hung call would hang the CLI with it. So a
  /// command waits for its child with a deadline, reads the child's output on another thread (a read to the end of
  /// a pipe would block before any deadline began), and stops a child that outlives the deadline: SIGTERM, then
  /// SIGKILL. A grandchild that keeps the pipe open cannot hold the CLI either: once the child has exited, its output
  /// is waited for only briefly.
  ///
  /// Two deliberate differences from agentctl-android's helper (agreed for 0.5, not drift):
  /// - Only the child is stopped, not its descendants. `simctl` does its work in CoreSimulator's XPC services, which
  ///   are not its children, so there are no descendants worth stopping; and a grandchild cannot block the CLI here.
  /// - No per-device skip. `simctl list` reports every simulator in one call, so a frozen simulator cannot make the
  ///   listing hang one device at a time the way `adb shell getprop` can; if the call itself times out, the command
  ///   fails (exit 3) and says CoreSimulator may be stuck.
  enum Shell {
    /// Simulator operations that answer in seconds when CoreSimulator is healthy: `list`, `terminate`, `launch`,
    /// `screenshot`, `status_bar`, `get_app_container`.
    static let quick: TimeInterval = 60
    /// Booting a simulator or installing the app, which can take minutes on a cold machine.
    static let slow: TimeInterval = 300
    /// The exit status ``run(_:in:log:append:timeout:)`` returns for a child it had to stop.
    static let timedOut: Int32 = -2

    static func which(_ tool: String) -> Bool {
      capture(["which", tool], in: URL(fileURLWithPath: "/"), timeout: 10).contains("/")
    }

    /// Runs a command with its output in `log`; returns its exit status, or ``timedOut`` when it had to be stopped
    /// after `timeout` seconds (`nil`: no limit, for builds). A timeout is noted at the end of the log.
    @discardableResult
    static func run(
      _ arguments: [String], in directory: URL, log: URL, append: Bool = false, timeout: TimeInterval? = nil
    ) -> Int32 {
      try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !append || !FileManager.default.fileExists(atPath: log.path) {
        FileManager.default.createFile(atPath: log.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      let process = Self.process(arguments, in: directory)
      process.standardOutput = handle
      process.standardError = handle
      guard let exited = start(process) else { return -1 }
      guard wait(for: process, exited: exited, timeout: timeout) else {
        handle.write(Data("\nagentctl: \(arguments.joined(separator: " ")) did not finish within \(Int(timeout ?? 0)) s; stopped it\n".utf8))
        return timedOut
      }
      return process.terminationStatus
    }

    /// Like ``run(_:in:log:append:timeout:)``, but watches the log. Once `isFinished(log)` is true, the process gets
    /// `grace` seconds to exit before it is stopped; it is always stopped after `timeout`. `xcodebuild test`
    /// sometimes hangs after the test run has finished. Returns the exit status, or nil if the process had to be
    /// stopped.
    static func runWatched(
      _ arguments: [String],
      in directory: URL,
      log: URL,
      grace: TimeInterval = 20,
      timeout: TimeInterval = 900,
      isFinished: (String) -> Bool
    ) -> Int32? {
      try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: log.path, contents: nil)
      guard let handle = try? FileHandle(forWritingTo: log) else { return -1 }
      defer { try? handle.close() }
      let process = Self.process(arguments, in: directory)
      process.standardOutput = handle
      process.standardError = handle
      guard start(process) != nil else { return -1 }
      let start = Date()
      var finishedAt: Date?
      while process.isRunning {
        Thread.sleep(forTimeInterval: 0.5)
        if finishedAt == nil, let text = try? String(contentsOf: log, encoding: .utf8), isFinished(text) {
          finishedAt = Date()
        }
        let lingering = finishedAt.map { Date().timeIntervalSince($0) > grace } ?? false
        if lingering || Date().timeIntervalSince(start) > timeout {
          stop(process)
          return nil
        }
      }
      return process.terminationStatus
    }

    /// Runs a command and returns its standard output, or what it had printed when it had to be stopped after
    /// `timeout` seconds (for the tools that print nothing until they are done, that is nothing).
    static func capture(_ arguments: [String], in directory: URL, timeout: TimeInterval = quick) -> String {
      captureResult(arguments, in: directory, timeout: timeout).output
    }

    /// ``capture(_:in:timeout:)``, saying whether the command finished in time.
    static func captureResult(
      _ arguments: [String], in directory: URL, timeout: TimeInterval = quick
    ) -> (output: String, finished: Bool) {
      let process = Self.process(arguments, in: directory)
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      // Read on another thread: reading to the end here would block until the pipe closes, before any deadline.
      let output = Output()
      let reader = DispatchSemaphore(value: 0)
      guard let exited = start(process) else { return ("", false) }
      DispatchQueue.global().async {
        output.set(pipe.fileHandleForReading.readDataToEndOfFile())
        reader.signal()
      }
      let finished = wait(for: process, exited: exited, timeout: timeout)
      // A grandchild that inherited the pipe keeps it open after the child is gone; do not wait on it for long.
      _ = reader.wait(timeout: .now() + 1)
      return (String(decoding: output.data, as: UTF8.self), finished)
    }

    // MARK: - Helpers

    private static func process(_ arguments: [String], in directory: URL) -> Process {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = arguments
      process.currentDirectoryURL = directory
      return process
    }

    /// Starts `process` and returns a semaphore signalled when it exits, or `nil` if it could not start.
    private static func start(_ process: Process) -> DispatchSemaphore? {
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      do { try process.run() } catch { return nil }
      return exited
    }

    /// Waits for `process` to exit, at most `timeout` seconds (`nil`: for ever). Stops it and returns `false` if it
    /// did not.
    private static func wait(for process: Process, exited: DispatchSemaphore, timeout: TimeInterval?) -> Bool {
      guard let timeout else {
        exited.wait()
        return true
      }
      if exited.wait(timeout: .now() + timeout) == .success { return true }
      stop(process)
      return false
    }

    /// SIGTERM, and SIGKILL for a child that is still there two seconds later (one that ignores SIGTERM).
    static func stop(_ process: Process) {
      guard process.isRunning else { return }
      process.terminate()
      let deadline = Date().addingTimeInterval(2)
      while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// The output a reader thread collects, handed back under a lock.
    private final class Output: @unchecked Sendable {
      private let lock = NSLock()
      private var value = Data()
      var data: Data { lock.withLock { value } }
      func set(_ data: Data) { lock.withLock { value = data } }
    }
  }
#endif
