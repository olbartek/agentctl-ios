import Foundation

/// The outcome of one script command, as printed by `appctl run` and returned by AgentBridge.
public struct StepRecord: Equatable, Sendable {
  public var command: String
  public var screen: String
  public var summary: [SummaryItem]
  public var calls: [String]
  public var error: String?
  public var pending: Int
  /// `false` when settling hit its real-time limit.
  public var settled: Bool
  public var ok: Bool
  /// Why the step failed, or extra detail (for `--diff`, see ``diff``).
  public var message: String?
  public var diff: String?

  public init(
    command: String,
    screen: String,
    summary: [SummaryItem],
    calls: [String],
    error: String?,
    pending: Int,
    settled: Bool = true,
    ok: Bool = true,
    message: String? = nil,
    diff: String? = nil
  ) {
    self.command = command
    self.screen = screen
    self.summary = summary
    self.calls = calls
    self.error = error
    self.pending = pending
    self.settled = settled
    self.ok = ok
    self.message = message
    self.diff = diff
  }

  public var snapshot: StepSnapshot {
    StepSnapshot(screen: screen, summary: summary, calls: calls, error: error, pending: pending)
  }
}

/// Renders steps in the formats of spec §5.3.
public enum StepFormatter {
  /// ```text
  /// > submit
  ///   screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders
  /// ```
  public static func text(_ step: StepRecord) -> String {
    var fields = ["screen=\(step.screen)"]
    fields += step.summary.map { "\($0.key)=\(quoted($0.value))" }
    if !step.calls.isEmpty { fields.append("calls=\(step.calls.joined(separator: ","))") }
    if let error = step.error { fields.append("error=\(error)") }
    if step.pending != 0 { fields.append("pending=\(step.pending)") }
    if !step.settled { fields.append("settled=false") }
    var lines = ["> \(step.command)", "  " + fields.joined(separator: " ")]
    if let message = step.message {
      lines += message.split(separator: "\n", omittingEmptySubsequences: false).map {
        "  \(step.ok ? "" : "FAIL ")\($0)"
      }
    }
    if let diff = step.diff, !diff.isEmpty {
      lines += diff.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }
    }
    return lines.joined(separator: "\n")
  }

  public static func text(_ steps: [StepRecord]) -> String {
    steps.map(text).joined(separator: "\n")
  }

  /// A JSON array of `{command, screen, summary, calls, error, pending, ok, …}` with sorted keys.
  public static func json(_ steps: [StepRecord]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(steps.map(JSONStep.init)) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func quoted(_ value: String) -> String {
    value.contains(where: \.isWhitespace) || value.isEmpty ? "\"\(value)\"" : value
  }
}

private struct JSONStep: Encodable {
  var command: String
  var screen: String
  var summary: [String: String]
  var calls: [String]
  var error: String?
  var pending: Int
  var settled: Bool
  var ok: Bool
  var message: String?

  init(_ step: StepRecord) {
    command = step.command
    screen = step.screen
    summary = Dictionary(step.summary.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    calls = step.calls
    error = step.error
    pending = step.pending
    settled = step.settled
    ok = step.ok
    message = step.message
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(command, forKey: .command)
    try container.encode(screen, forKey: .screen)
    try container.encode(summary, forKey: .summary)
    try container.encode(calls, forKey: .calls)
    try container.encode(error, forKey: .error)
    try container.encode(pending, forKey: .pending)
    try container.encode(settled, forKey: .settled)
    try container.encode(ok, forKey: .ok)
    try container.encodeIfPresent(message, forKey: .message)
  }

  enum CodingKeys: String, CodingKey {
    case command, screen, summary, calls, error, pending, settled, ok, message
  }
}
