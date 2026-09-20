import AgentCtlTCA
import Foundation
import Testing

/// Every test that drives an app runs under this serialized suite: the main serial executor is process-global
/// state, so tests that enable it must not overlap.
@Suite(.serialized)
enum AgentCtlSuite {}

/// The package's own directories, found from this file rather than from the working directory, which differs
/// between `swift test`, Xcode and an editor.
enum PackageRoot {
  /// `<package>/Tests/AgentCtlTests/<file>` → `<package>`.
  static let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  /// The example app's scenarios: the same files `tinyctl test` runs.
  static let scenarios = url.appending(path: "Examples/TinyApp/scenarios")
}

/// Runs `operation` with the main serial executor (deterministic scheduling) and returns its value.
@MainActor
func serially<T>(_ operation: @MainActor () async -> T) async -> T {
  let previous = Deterministic.isEnabled
  Deterministic.isEnabled = true
  defer { Deterministic.isEnabled = previous }
  return await operation()
}
