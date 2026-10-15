// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import Foundation

  /// Finds a host's repo root: the nearest directory, at or above a starting point, that contains the config's root
  /// marker (``AppCtlConfig/resolvedRootMarker``).
  ///
  /// One walk for every caller, so the CLI (starting from the working directory) and a host's tests (starting from
  /// their own source file, since `swift test`, Xcode and an editor each run from a different directory) agree on
  /// where `scenariosPath` and `docsPath` are resolved from.
  public enum RepoRoot {
    /// The nearest directory at or above `start` that contains `marker` (a path relative to it, such as
    /// `Package.swift` or `App/MyApp.xcodeproj`), or `nil` when no ancestor does. A `start` that is a file begins
    /// the walk at its directory.
    public static func find(marker: String, from start: URL) -> URL? {
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory)
      var directory = exists && !isDirectory.boolValue ? start.deletingLastPathComponent() : start
      directory = directory.standardizedFileURL
      while true {
        if FileManager.default.fileExists(atPath: directory.appending(path: marker).path) {
          return directory
        }
        // `/` has one path component; deleting the last component of `/` gives `/..`, not a stop.
        guard directory.pathComponents.count > 1 else { return nil }
        directory = directory.deletingLastPathComponent()
      }
    }
  }
#endif
