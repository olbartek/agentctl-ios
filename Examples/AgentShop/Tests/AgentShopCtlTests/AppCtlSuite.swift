import AgentCtlTCA
import Foundation
import Testing

/// Every AppCtl test runs under this serialized suite: the main serial executor is process-global state,
/// so tests that enable it must not overlap.
@Suite(.serialized)
enum AppCtlSuite {}

enum Repo {
  /// The directory above this file that holds `App/AgentShop.xcodeproj`, the same marker the CLI looks for, so
  /// moving the package does not break the tests.
  static let root: URL = {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.appending(path: "App/AgentShop.xcodeproj").path) {
      let parent = directory.deletingLastPathComponent()
      precondition(parent != directory, "no App/AgentShop.xcodeproj above \(#filePath)")
      directory = parent
    }
    return directory
  }()

  static let scenarios = root.appending(path: "scenarios")
}

/// Runs `operation` with the main serial executor (deterministic scheduling) and returns its value.
@MainActor
func serially<T>(_ operation: @MainActor () async -> T) async -> T {
  let previous = Deterministic.isEnabled
  Deterministic.isEnabled = true
  defer { Deterministic.isEnabled = previous }
  return await operation()
}
