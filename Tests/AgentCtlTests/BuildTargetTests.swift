import AgentCtlTCA
import Testing

/// `.project` exists only so host repos without a `.xcworkspace` can use AgentCtl; nothing else exercises it.
/// An untested mandated case is how a package ships a broken option, so both cases get their own assertions.
@Suite
struct BuildTargetTests {
  @Test
  func workspaceArguments() {
    let target = BuildTarget.workspace("App.xcworkspace", scheme: "App")
    #expect(target.xcodebuildArguments == ["-workspace", "App.xcworkspace", "-scheme", "App"])
    #expect(target.scheme == "App")
    #expect(target.path == "App.xcworkspace")
  }

  @Test
  func projectArguments() {
    let target = BuildTarget.project("App.xcodeproj", scheme: "App")
    #expect(target.xcodebuildArguments == ["-project", "App.xcodeproj", "-scheme", "App"])
    #expect(target.scheme == "App")
    #expect(target.path == "App.xcodeproj")
  }
}
