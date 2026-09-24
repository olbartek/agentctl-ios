#if os(macOS)
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  /// What this guards: how L3 picks the scheme and the test targets for a snapshot package, which a package with
  /// several products, or a snapshot target named after the module it tests, used to break (issue #2).
  ///
  /// What it does not guard: that `xcodebuild` then runs those tests, which needs a simulator.
  @Suite
  struct SnapshotRunnerTests {
    @Test
    func aSingleProductPackageIsTestedWithTheSchemeNamedAfterIt() {
      #expect(SnapshotRunner.scheme(for: "Auth", listed: ["Auth"]) == "Auth")
    }

    @Test
    func aPackageWithSeveralProductsIsTestedWithItsPackageScheme() {
      #expect(SnapshotRunner.scheme(for: "Shared", listed: ["DesignSystem", "Models", "Shared-Package"]) == "Shared-Package")
    }

    @Test
    func aLoneSchemeNamedAfterTheProductIsUsed() {
      #expect(SnapshotRunner.scheme(for: "Auth", listed: ["AuthFeature"]) == "AuthFeature")
    }

    @Test
    func noSchemeWhenNoneFits() {
      #expect(SnapshotRunner.scheme(for: "Shared", listed: ["DesignSystem", "Models"]) == nil)
      #expect(SnapshotRunner.scheme(for: "Shared", listed: []) == nil)
    }

    @Test
    func schemesAreReadFromXcodebuildListJSON() {
      let package = """
        Command line invocation: …
        {
          "workspace" : {
            "name" : "Shared",
            "schemes" : [ "DesignSystem", "Models", "Shared-Package" ]
          }
        }
        """
      #expect(SnapshotRunner.schemes(inListJSON: package) == ["DesignSystem", "Models", "Shared-Package"])
      #expect(SnapshotRunner.schemes(inListJSON: #"{"project": {"schemes": ["App"]}}"#) == ["App"])
      #expect(SnapshotRunner.schemes(inListJSON: "xcodebuild: error: no package").isEmpty)
    }

    @Test
    func theTargetsAreTheSnapshotTestDirectories() throws {
      let package = FileManager.default.temporaryDirectory.appending(path: "SnapshotRunnerTests-\(UUID())")
      defer { try? FileManager.default.removeItem(at: package) }
      for name in ["ModelsTests", "DesignSystemSnapshotTests", "AppSnapshotTests"] {
        try FileManager.default.createDirectory(at: package.appending(path: "Tests/\(name)"), withIntermediateDirectories: true)
      }
      // A file with the suffix is not a target.
      FileManager.default.createFile(atPath: package.appending(path: "Tests/NotesSnapshotTests").path, contents: Data())
      #expect(SnapshotRunner.snapshotTargets(in: package) == ["AppSnapshotTests", "DesignSystemSnapshotTests"])
      #expect(SnapshotRunner.snapshotTargets(in: package.appending(path: "Missing")).isEmpty)
    }
  }
#endif
