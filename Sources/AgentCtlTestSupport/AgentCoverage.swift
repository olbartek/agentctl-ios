import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation

/// Thrown by `AgentCoverage.init` when `scenarios` has no `*.appctl` files to check.
///
/// Every guard on ``AgentCoverage`` answers "what's missing" by scanning the scenario files found at
/// `scenarios`; an empty result means "no problems found". That reading is only meaningful if there were
/// scenario files to scan in the first place. A misconfigured or renamed `scenarios` directory would
/// otherwise make ``AgentCoverage/unusedCommands()``, ``AgentCoverage/undocumentedSummaryKeys()`` and
/// ``AgentCoverage/unvisitedScreens()`` each return an empty array — a guard that always passes without
/// having examined anything, which is exactly the failure this suite exists to catch. `init` refuses to
/// build an `AgentCoverage` in that situation instead, naming the exact path it looked at. It does not search
/// parent directories or otherwise guess at the right one: a wrong path is a bug to fix, not to work around.
public struct NoScenariosFound: Error, Equatable, Sendable, CustomStringConvertible {
  public var scenarios: URL

  public init(scenarios: URL) {
    self.scenarios = scenarios
  }

  public var description: String {
    "AgentCoverage: no *.appctl files found at \(scenarios.path) — check the `scenarios` argument passed to "
      + "AgentCoverage.init; every coverage guard would otherwise report success without checking anything."
  }
}

/// The guards that keep an app's agent surface honest as screens are added.
///
/// Construct one with every screen the app documents (its `AgentContainer.registry`) and the directory its
/// `*.appctl` scenarios live in, then ask:
/// - ``unusedCommands()``: command names no scenario sends.
/// - ``undocumentedSummaryKeys()``: summary keys a scenario run emits that no screen's `summaryKeys` lists.
/// - ``unvisitedScreens()``: documented screen paths no scenario run visits. A pattern segment written
///   `<id>` (e.g. `home/orders/<id>`) matches any concrete segment (`home/orders/1003`), so a screen with a
///   variable path only needs one scenario to reach some instance of it, not every possible one.
///
/// All three run the same fixed set of scenario files, read once when this value is constructed — later
/// changes to the directory on disk aren't picked up without constructing a new `AgentCoverage`.
///
/// ## What this does not cover
/// A `nil`/empty result from a guard means the scenarios that exist don't exhibit the problem; it says
/// nothing about scenarios that don't exist. In particular these guards cannot tell a thorough scenario
/// suite from a thin one that happens to touch every command once. They also cannot tell a scenario file
/// that runs and asserts nothing meaningful from one that does: `unusedCommands` only checks that a command
/// *appears* in some script, not that running it was checked with `expect`.
///
/// ## The empty-scenarios guard
/// Because an empty scenario list would make every guard above pass vacuously, `init` throws
/// ``NoScenariosFound`` when `scenarios` contains zero `*.appctl` files — whether the directory is missing,
/// empty, or simply the wrong path. There is no way to construct an `AgentCoverage` whose guards silently
/// check nothing.
@MainActor
public struct AgentCoverage<Root: Reducer & AgentContainer>
where Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
  Root.AgentState == Root.State, Root.AgentAction == Root.Action
{
  let screens: [ScreenDoc]
  let files: [URL]
  let make: @MainActor () -> ScriptRunner<Root>

  /// The number of `*.appctl` files this instance found at `scenarios`. `init` already guarantees this is
  /// greater than zero; exposed so a host can log it, or assert a lower bound of its own (e.g. that a
  /// refactor of the scenarios directory didn't quietly drop files down to just one).
  public var scenarioCount: Int { files.count }

  /// - Throws: ``NoScenariosFound`` if `scenarios` contains no `*.appctl` files.
  public init(screens: [ScreenDoc], scenarios: URL, make: @escaping @MainActor () -> ScriptRunner<Root>) throws {
    let files = ScenarioRunner.files(in: scenarios)
    guard !files.isEmpty else { throw NoScenariosFound(scenarios: scenarios) }
    self.screens = screens
    self.files = files
    self.make = make
  }

  /// Command names no scenario sends.
  public func unusedCommands() throws -> [String] {
    var used: Set<String> = []
    for file in files {
      let lines = try ScriptParser.parse(try String(contentsOf: file, encoding: .utf8))
      used.formUnion(lines.map(\.name))
    }
    return AgentRegistry.allCommandNames(screens: screens).subtracting(used).sorted()
  }

  /// Summary keys emitted during the scenarios that no screen documents.
  public func undocumentedSummaryKeys() async -> [String] {
    var undocumented: Set<String> = []
    for file in files {
      let result = await ScenarioRunner.run(file: file, make: make)
      for step in result.steps {
        guard let doc = screens.first(where: { Self.matches(pattern: $0.path, path: step.screen) }) else {
          undocumented.insert("\(step.screen): no documented screen")
          continue
        }
        for item in step.summary where !doc.summaryKeys.contains(item.key) {
          undocumented.insert("\(doc.path): \(item.key)")
        }
      }
    }
    return undocumented.sorted()
  }

  /// Documented screens no scenario visits.
  public func unvisitedScreens() async -> [String] {
    var visited: Set<String> = []
    for file in files {
      let result = await ScenarioRunner.run(file: file, make: make)
      visited.formUnion(result.steps.map(\.screen))
    }
    return screens.map(\.path).filter { pattern in
      !visited.contains { Self.matches(pattern: pattern, path: $0) }
    }
  }

  /// `home/orders/<id>` matches `home/orders/1003`.
  public static func matches(pattern: String, path: String) -> Bool {
    let patternParts = pattern.split(separator: "/")
    let pathParts = path.split(separator: "/")
    guard patternParts.count == pathParts.count else { return false }
    return zip(patternParts, pathParts).allSatisfy { $0.hasPrefix("<") || $0 == $1 }
  }
}
