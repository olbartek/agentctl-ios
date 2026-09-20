import AgentCtlCore
import ComposableArchitecture
import Foundation

public struct ScenarioResult: Sendable {
  public var name: String
  public var steps: [StepRecord]
  public var status: RunStatus
  public var failedLine: ScriptLine?
  public var message: String?
  public var duration: Duration

  public var passed: Bool { status == .ok }

  /// `PASS name (N steps, X ms)` or `FAIL name:line` followed by the failing step.
  public var report: String {
    let milliseconds = Int(duration.components.seconds) * 1000
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    guard !passed else { return "PASS \(name) (\(steps.count) steps, \(milliseconds) ms)" }
    var lines = ["FAIL \(name)\(failedLine.map { ":\($0.line)" } ?? "")"]
    if let message { lines.append("  \(message)") }
    if let failing = steps.last {
      lines += StepFormatter.text(failing).split(separator: "\n").map { "  \($0)" }
    }
    return lines.joined(separator: "\n")
  }
}

/// Runs `scenarios/*.appctl` files, each against a fresh ``ScriptRunner`` from `make`.
@MainActor
public enum ScenarioRunner {
  public static func run<Root: Reducer & AgentContainer>(
    name: String,
    source: String,
    make: @MainActor () -> ScriptRunner<Root>
  ) async -> ScenarioResult
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    let clock = ContinuousClock()
    let start = clock.now
    let runner = make()
    let launch = await runner.launch()
    let result = await runner.run(source)
    return ScenarioResult(
      name: name,
      steps: [launch] + result.steps,
      status: result.status,
      failedLine: result.failedLine,
      message: result.message,
      duration: start.duration(to: clock.now)
    )
  }

  public static func run<Root: Reducer & AgentContainer>(
    file: URL,
    make: @MainActor () -> ScriptRunner<Root>
  ) async -> ScenarioResult
  where
    Root.State: Equatable, Root.State: ObservableState, Root.Action: Sendable,
    Root.AgentState == Root.State, Root.AgentAction == Root.Action
  {
    let name = file.deletingPathExtension().lastPathComponent
    guard let source = try? String(contentsOf: file, encoding: .utf8) else {
      return ScenarioResult(
        name: name, steps: [], status: .usage, failedLine: nil, message: "cannot read \(file.path)", duration: .zero
      )
    }
    return await run(name: name, source: source, make: make)
  }

  /// Every `*.appctl` file in `directory`, sorted by name.
  nonisolated public static func files(in directory: URL) -> [URL] {
    let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.pathExtension == "appctl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}
