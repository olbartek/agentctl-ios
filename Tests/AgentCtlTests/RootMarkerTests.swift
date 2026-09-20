import AgentCtlTCA
import Foundation
import Testing
import TinyApp

/// What this guards: how the CLI finds the repo root, which is where `scenariosPath` and the generated docs are
/// resolved from. A host with an Xcode project is marked by it and sets nothing; a host with nothing to build —
/// the example — names a file of its own, and that file has to be there.
@MainActor
@Suite
struct RootMarkerTests {
  @Test
  func aHostThatSetsNoMarkerIsMarkedByItsBuildTarget() {
    var config = TinyAppConfig.appCtl
    config.rootMarker = nil
    config.target = .workspace("MyApp.xcworkspace", scheme: "MyApp")
    #expect(ErasedConfig(config: config).rootMarker == "MyApp.xcworkspace")
  }

  @Test
  func theExampleNamesAMarkerThatExists() {
    let marker = ErasedConfig(config: TinyAppConfig.appCtl).rootMarker
    #expect(marker == "Package.swift")
    #expect(FileManager.default.fileExists(atPath: PackageRoot.url.appending(path: marker).path))
    // The example has no project to build, so the marker cannot be the build target's path.
    #expect(marker != TinyAppConfig.appCtl.target.path)
  }
}
