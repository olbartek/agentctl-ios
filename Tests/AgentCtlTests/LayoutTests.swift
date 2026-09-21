#if os(macOS)
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  // Nested in the serialized `AgentCtlSuite`: the output directory comes from the process-global runtime.
  extension AgentCtlSuite {
    /// What this guards: the CLI assumes no repository layout. A package is wherever its configured path says,
    /// named by that path's last component, and everything the CLI writes goes under the configured output path.
    @MainActor
    @Suite
    struct LayoutTests {
      let layout = Layout(root: URL(filePath: "/work/my-app"))

      @Test
      func aPackageIsWhereItsPathSaysAndNamedByItsLastComponent() {
        #expect(layout.directory(ofPackage: "Packages/Features/Auth").path == "/work/my-app/Packages/Features/Auth")
        #expect(layout.name(ofPackage: "Packages/Features/Auth") == "Auth")
        #expect(layout.name(ofPackage: "Modules/Core/Shared/") == "Shared")
        #expect(layout.name(ofPackage: "Tools/../Tools/AppCtl") == "AppCtl")
      }

      /// A package at the root is `.`, and is named after the root's own directory.
      @Test
      func theRootPackageIsDot() {
        #expect(layout.directory(ofPackage: ".").path == "/work/my-app")
        #expect(layout.name(ofPackage: ".") == "my-app")
      }

      @Test
      func everythingTheCLIWritesGoesUnderTheOutputPath() {
        AgentCtl.install(StubRuntime())
        #expect(layout.output.path == "/work/my-app/.xctl")
        #expect(layout.logs.path == "/work/my-app/.xctl/logs")
        #expect(layout.screenshots.path == "/work/my-app/.xctl/screenshots")
        #expect(layout.snapshotFailures.path == "/work/my-app/.xctl/snapshot-failures")
        #expect(layout.derivedData.path == "/work/my-app/.xctl/DerivedData")
      }
    }
  }
#endif
