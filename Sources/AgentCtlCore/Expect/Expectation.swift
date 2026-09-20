/// What an `expect` step is checked against: the state after the previous step.
public struct StepSnapshot: Equatable, Sendable {
  public var screen: String
  public var summary: [SummaryItem]
  /// Mock calls made during the previous step.
  public var calls: [String]
  public var error: String?
  public var pending: Int

  public init(screen: String, summary: [SummaryItem], calls: [String], error: String?, pending: Int) {
    self.screen = screen
    self.summary = summary
    self.calls = calls
    self.error = error
    self.pending = pending
  }
}

/// `expect k=v [k=v …]`.
///
/// Keys: `screen`, any summary key, `call` (repeatable; the method was called during the previous step),
/// `error` (`none` = no error) and `pending` (effects still in flight).
public struct Expectation: Equatable, Sendable {
  public struct Pair: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
      self.key = key
      self.value = value
    }
  }

  public var pairs: [Pair]

  public init(pairs: [Pair]) {
    self.pairs = pairs
  }

  public static let reservedKeys = ["screen", "call", "error", "pending"]

  /// Parses the argument of `expect`. Values containing spaces must be quoted: `name="Alice Smith"`.
  public static func parse(_ argument: String?) throws(ExpectationSyntaxError) -> Self {
    guard let argument else { throw ExpectationSyntaxError(message: "expect needs at least one key=value pair") }
    var pairs: [Pair] = []
    for token in ArgumentText.tokens(argument) {
      guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
        throw ExpectationSyntaxError(message: "expected key=value, got '\(token)'")
      }
      pairs.append(Pair(String(token[..<equals]), String(token[token.index(after: equals)...])))
    }
    return Self(pairs: pairs)
  }

  /// Returns one failure message per unmet pair; empty when everything matches.
  public func evaluate(_ snapshot: StepSnapshot) -> [String] {
    pairs.compactMap { (pair: Pair) -> String? in
      switch pair.key {
      case "screen":
        return snapshot.screen == pair.value ? nil : mismatch(pair, actual: snapshot.screen)
      case "call":
        guard !snapshot.calls.contains(pair.value) else { return nil }
        let calls = snapshot.calls.isEmpty ? "none" : snapshot.calls.joined(separator: ",")
        return "expected call=\(pair.value), got calls=\(calls)"
      case "error":
        let actual = snapshot.error ?? "none"
        return actual == pair.value ? nil : mismatch(pair, actual: actual)
      case "pending":
        return String(snapshot.pending) == pair.value ? nil : mismatch(pair, actual: String(snapshot.pending))
      default:
        guard let item = snapshot.summary.first(where: { $0.key == pair.key }) else {
          let available = (Self.reservedKeys + snapshot.summary.map(\.key)).joined(separator: ", ")
          return "unknown key '\(pair.key)' on \(snapshot.screen); available: \(available)"
        }
        return item.value == pair.value ? nil : mismatch(pair, actual: item.value)
      }
    }
  }

  private func mismatch(_ pair: Pair, actual: String) -> String {
    "expected \(pair.key)=\(pair.value), got \(pair.key)=\(actual)"
  }
}

public struct ExpectationSyntaxError: Error, Equatable, Sendable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}
