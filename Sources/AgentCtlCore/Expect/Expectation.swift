/// What an `expect` step is checked against: the state after the previous step.
public struct StepSnapshot: Equatable, Sendable {
  public var screen: String
  public var summary: [SummaryItem]
  /// Mock calls made during the previous step.
  public var calls: [String]
  public var error: String?
  public var pending: Int
  /// The system prompt the app is waiting on, if any.
  public var prompt: String?

  public init(
    screen: String, summary: [SummaryItem], calls: [String], error: String?, pending: Int, prompt: String? = nil
  ) {
    self.screen = screen
    self.summary = summary
    self.calls = calls
    self.error = error
    self.pending = pending
    self.prompt = prompt
  }
}

/// `expect k=v [k=v …]`.
///
/// Keys: `screen`, any summary key, `call` (repeatable; the method was called during the previous step),
/// `error` (`none` = no error), `pending` (sleeps waiting on the clock, such as a countdown — see
/// ``CountingClock/activeSleeps``) and `prompt` (the system prompt the app is waiting on; `none` = no prompt).
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

  public static let reservedKeys = ["screen", "call", "error", "pending", "prompt"]

  /// Parses the argument of `expect`. Values containing spaces must be quoted: `name="Alice Smith"`. Each token's
  /// first unquoted `=` splits it; a token whose `=` is only inside quotes is a syntax error.
  public static func parse(_ argument: String?) throws(ExpectationSyntaxError) -> Self {
    guard let argument else { throw ExpectationSyntaxError(message: "expect needs at least one key=value pair") }
    var pairs: [Pair] = []
    for (token, pair) in ArgumentText.pairs(argument) {
      // The `=` must be outside quotes: `"title=Second item"` is one quoted value, not a pair (CONTRACT.md §2.1).
      guard let pair else { throw ExpectationSyntaxError(message: "expected key=value, got '\(token)'") }
      pairs.append(Pair(pair.key, pair.value))
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
      case "prompt":
        let actual = snapshot.prompt ?? "none"
        return actual == pair.value ? nil : mismatch(pair, actual: actual)
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

/// `wait [<duration>] [k=v …]` (CONTRACT.md §2.5): how long to wait, and for what. With pairs, until they all
/// match, as `expect` would check them; with none, until the screen's line changes.
public struct AgentWaitArguments: Equatable, Sendable {
  /// How long a `wait` that names no duration waits.
  public static var defaultDuration: Duration { .seconds(10) }

  public var duration: Duration
  /// `nil`: wait for the screen's path, summary, error or prompt to change.
  public var expectation: Expectation?

  public init(duration: Duration = Self.defaultDuration, expectation: Expectation? = nil) {
    self.duration = duration
    self.expectation = expectation
  }

  /// Parses the argument of `wait`: an optional duration first (`30s`, as `advance` takes it), then `key=value`
  /// pairs, as `expect` takes them.
  public static func parse(_ argument: String?) throws(ExpectationSyntaxError) -> Self {
    var tokens = ArgumentText.pairs(argument ?? "")[...]
    var duration = defaultDuration
    if let first = tokens.first, first.pair == nil {
      guard let parsed = ScriptParser.parseDuration(first.token) else {
        throw ExpectationSyntaxError(
          message: "usage: wait [<duration>] [key=value …]; a duration such as 500ms, 30s, 5m or 1h, got '\(first.token)'"
        )
      }
      duration = parsed
      tokens = tokens.dropFirst()
    }
    var pairs: [Expectation.Pair] = []
    for (token, pair) in tokens {
      guard let pair else { throw ExpectationSyntaxError(message: "expected key=value, got '\(token)'") }
      pairs.append(Expectation.Pair(pair.key, pair.value))
    }
    return Self(duration: duration, expectation: pairs.isEmpty ? nil : Expectation(pairs: pairs))
  }
}

public struct ExpectationSyntaxError: Error, Equatable, Sendable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}
