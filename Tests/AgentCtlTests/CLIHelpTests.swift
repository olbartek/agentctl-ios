#if os(macOS)
  import AgentCtlCore
  import AgentCtlTCA
  import ArgumentParser
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  /// What this guards: every string the CLI prints that names the CLI or its commands — the help page of each
  /// subcommand, and the messages in ``Message`` — must be rendered from the host's ``HelpExamples``. The tests
  /// install a stub host whose invocation is `xctl` and whose commands are `refresh`/`open <id>`, then read the
  /// real `CommandConfiguration`s back and fail on any `appctl` spelling or PoC vocabulary that survived.
  ///
  /// What it does not guard: the CLI's behaviour (no command is executed here), the repo-layout strings
  /// (`Packages/…`, `docs/agent-commands.md`), or anything the host itself puts in `HelpExamples`.
  @MainActor
  @Suite(.serialized)
  struct CLIHelpTests {
    /// Every help page the CLI can print, keyed by the subcommand it belongs to.
    static var pages: [(name: String, text: String)] {
      AgentCtl.install(StubRuntime())
      let commands: [(String, any ParsableCommand.Type)] = [
        ("(root)", AppCtlCommand.self), ("run", Run.self), ("state", StateCommand.self), ("screens", Screens.self),
        ("docs", Docs.self), ("test", Test.self), ("snapshots", Snapshots.self), ("check", Check.self),
        ("app", AppCommand.self), ("app launch", AppLaunch.self), ("app run", AppRun.self),
        ("app state", AppState.self), ("app screens", AppScreens.self),
      ]
      return commands.map { ($0.0, $0.1.helpMessage(columns: 100)) }
    }

    /// Strips the places `appctl` is a fixed token rather than the CLI's name: the scenario file extension (and
    /// the `.appctl/` working directory), the launch argument the DEBUG app parses, the root environment
    /// variable and the bridge's exit-code header.
    static func withoutFixedTokens(_ text: String) -> String {
      ["-appctl-seed", ".appctl", "APPCTL_ROOT", "X-Appctl-Exit"].reduce(text) {
        $0.replacingOccurrences(of: $1, with: "")
      }
    }

    static let hostWords = ["alice", "bob@", "login-as", "home/orders", "auth/login", "tab profile", "order-cancel"]

    /// Every CLI source file, with comments stripped, so what remains is code and the strings it prints.
    static func cliCodeWithoutComments() throws -> [(name: String, text: String)] {
      let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/AgentCtlTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the package root
        .appending(path: "Sources/AgentCtlCLI")
      let files = try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
      return try files.map { file in
        let code = try String(contentsOf: file, encoding: .utf8)
          .split(separator: "\n", omittingEmptySubsequences: false)
          .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
          .joined(separator: "\n")
        return (file.lastPathComponent, withoutFixedTokens(code))
      }
    }

    @Test
    func noHelpPageNamesThisPackagesCLI() {
      for page in Self.pages {
        let text = Self.withoutFixedTokens(page.text)
        let namesTheCLI = text.contains("appctl")
        let hostWords = Self.hostWords.filter { text.lowercased().contains($0) }
        #expect(!namesTheCLI, "the '\(page.name)' help page still names appctl")
        #expect(hostWords.isEmpty, "the '\(page.name)' help page still names \(hostWords)")
      }
    }

    /// The negative assertions above would pass on empty strings, so pin down that real pages were rendered and
    /// that they are written in the stub host's words.
    @Test
    func everyPageIsRenderedFromTheHostsExamples() {
      let pages = Self.pages
      #expect(pages.count == 13)
      for page in pages {
        #expect(page.text.count > 60, "'\(page.name)' help is suspiciously short:\n\(page.text)")
      }
      let all = pages.map(\.text).joined(separator: "\n")
      #expect(all.contains("Always call it through the xctl wrapper."))
      #expect(all.contains("xctl run \"refresh; open 1\""))
      #expect(all.contains("xctl test scenarios/browse.appctl"))
      #expect(all.contains("xctl app launch --seed \"refresh\""))
      // One per example line plus the command reference: a page that stopped interpolating would drop below this.
      #expect(all.components(separatedBy: "xctl ").count - 1 >= 15)
    }

    /// The help pages and ``Message`` are rendered surfaces; this one covers the rest of the target, so a new
    /// literal anywhere in the CLI — a `print`, an error, a report column — is caught too. It reads the sources
    /// next to this file, and fails loudly if it cannot find them rather than passing on an empty list.
    @Test
    func noCLISourceSpellsTheCLIsOwnName() throws {
      let files = try Self.cliCodeWithoutComments()
      #expect(files.count == 7, "expected the seven CLI files, found \(files.map(\.name).sorted())")
      for file in files {
        // The booleans are named so a failure reads as the file's name, not as a dump of the whole file.
        let length = file.text.count
        let spellsItsOwnName = file.text.contains("appctl")
        let hostWords = Self.hostWords.filter { file.text.lowercased().contains($0) }
        #expect(length > 200, "\(file.name) read as only \(length) characters of code")
        #expect(!spellsItsOwnName, "\(file.name) spells the CLI's own name in code; print `help.invocation`")
        #expect(hostWords.isEmpty, "\(file.name) names \(hostWords)")
      }
    }

    @Test
    func theMessagesThatNameTheCLIUseTheHostsInvocation() {
      AgentCtl.install(StubRuntime())
      let unreachable = Message.bridgeUnreachable(port: 8765, error: StubError())
      for message in [unreachable, Message.staleDocs, Message.staleDocsDetail] {
        #expect(!Self.withoutFixedTokens(message).contains("appctl"), "\(message)")
      }
      #expect(unreachable.contains("xctl app launch"))
      #expect(Message.staleDocs.contains("Run xctl docs."))
      #expect(Message.staleDocsDetail.contains("stale: run xctl docs"))
    }
  }

  private struct StubError: Error, CustomStringConvertible {
    var description = "connection refused"
  }

  /// A host that exists only so the help pages can be rendered: every fact is a placeholder, and the two
  /// store-building methods are never reached, because no test runs a command.
  private final class StubRuntime: AppCtlRuntime {
    let name = "StubApp"
    let target = BuildTarget.project("StubApp.xcodeproj", scheme: "StubApp")
    let bundleID = "com.example.stub"
    let packages = ["Stub"]
    let snapshotPackages = ["Stub"]
    let simulatorName = "iPhone 17 Pro"
    let snapshotSimulatorName = "iPhone 17 Pro"
    let snapshotRuntimeMajor = 18
    let scenariosPath = "scenarios"
    let appCheck = AppCheck()
    let screens: [ScreenDoc] = []
    let mockMethods = [MockMethod("items.fetch", errorCodes: ["network"])]
    let docsText = DocsText(title: "Stub", intro: "", usageExamples: [], appendix: [])
    let help = HelpExamples(
      invocation: "xctl",
      note: "Always call it through the xctl wrapper.",
      runScripts: ["refresh; open 1", "refresh", "expect screen=items"],
      scenarioPath: "scenarios/browse.appctl",
      appSeeds: ["refresh", "refresh; open 1"],
      appScripts: ["open 1; expect id=1", "refresh"]
    )

    func clearSession() {}

    @MainActor
    func makeRunner() -> any ScriptRunning {
      StubRunner()
    }

    @MainActor
    func runScenarios(_ files: [URL]) async -> [ScenarioResult] {
      []
    }
  }

  @MainActor
  private final class StubRunner: ScriptRunning {
    var recordsDiff = false
    let stateDump = "StubApp.State()"

    func launch() async -> StepRecord {
      snapshot(command: "(launch)")
    }

    func run(_ source: String) async -> RunResult {
      fatalError("the help tests never run a script")
    }

    func snapshot(command: String) -> StepRecord {
      StepRecord(command: command, screen: "items", summary: [], calls: [], error: nil, pending: 0)
    }
  }
#endif
