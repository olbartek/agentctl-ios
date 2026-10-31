import AgentCtlRuntime
import Foundation
import Testing

/// Every test that drives the app runs under this serialized suite: the main serial executor is process-global
/// state, so tests that enable it must not overlap.
@Suite(.serialized)
enum TinyMVVMSuite {}

/// The directories the tests read, found from this file rather than from the working directory, which differs
/// between `swift test`, Xcode and an editor.
enum PackageRoot {
  /// `<package>/Tests/TinyMVVMTests/<file>` → `<package>`.
  static let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  /// TinyApp's scenarios: the files `tinymvvmctl test` runs.
  static let scenarios = url.appending(path: "../TinyApp/scenarios").standardizedFileURL

  /// TinyApp's transcripts, kept current by the root package's `DriverParityTests`.
  static let transcripts = url.appending(path: "Tests/TinyMVVMTests/Fixtures/tinyapp-transcripts.json")
}

/// Runs `operation` with the main serial executor (deterministic scheduling) and returns its value.
@MainActor
func serially<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
  let previous = Deterministic.isEnabled
  Deterministic.isEnabled = true
  defer { Deterministic.isEnabled = previous }
  return try await operation()
}
