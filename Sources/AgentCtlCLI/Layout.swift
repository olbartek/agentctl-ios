#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import Foundation

  /// Every directory the CLI touches, derived from the repo root and the host's config.
  ///
  /// The CLI assumes no repository layout. It finds the root through the config's `rootMarker`, and every
  /// other path is one the config gives relative to it: packages, scenarios, the generated docs and the output
  /// directory.
  struct Layout {
    let root: URL

    /// Where logs, screenshots, snapshot failure images and build products go.
    var output: URL { root.appending(path: AgentCtl.runtime.outputPath) }
    var logs: URL { output.appending(path: "logs") }
    var screenshots: URL { output.appending(path: "screenshots") }
    var snapshotFailures: URL { output.appending(path: "snapshot-failures") }
    var derivedData: URL { output.appending(path: "DerivedData") }

    /// A package's directory, from its path in the config.
    func directory(ofPackage path: String) -> URL {
      root.appending(path: path).standardizedFileURL
    }

    /// A package's name: the last component of its path, so `.` names the root's own directory. It is the
    /// package's SwiftPM identity too, and so unique within one build graph, which makes it safe in log file
    /// names.
    func name(ofPackage path: String) -> String {
      directory(ofPackage: path).lastPathComponent
    }
  }
#endif
