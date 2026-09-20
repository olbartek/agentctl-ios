import Dependencies

/// How long mock backends pretend to take. 300–800 ms in the app, zero in `appctl` and tests.
///
/// When it is zero, mocks never touch the clock, which keeps them compatible with `TestClock`.
public struct MockLatency: Equatable, Sendable {
  public var range: ClosedRange<Duration>?

  public init(range: ClosedRange<Duration>?) {
    self.range = range
  }

  public static let zero = Self(range: nil)

  public static func fixed(_ duration: Duration) -> Self {
    Self(range: duration...duration)
  }

  public static func between(_ range: ClosedRange<Duration>) -> Self {
    Self(range: range)
  }

  public static func milliseconds(_ milliseconds: Int) -> Self {
    milliseconds <= 0 ? .zero : .fixed(.milliseconds(milliseconds))
  }

  /// A delay drawn from the range, or `.zero`. The generator is only used when the range is not a single value.
  public func sample(using generator: @autoclosure () -> WithRandomNumberGenerator) -> Duration {
    guard let range else { return .zero }
    let lower = range.lowerBound.milliseconds
    let upper = range.upperBound.milliseconds
    guard upper > lower else { return range.lowerBound }
    let random = generator()
    return .milliseconds(random { Int.random(in: lower...upper, using: &$0) })
  }
}

extension Duration {
  var milliseconds: Int {
    let (seconds, attoseconds) = components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

extension MockLatency: DependencyKey {
  public static let liveValue = MockLatency.between(.milliseconds(300) ... .milliseconds(800))
  public static let testValue = MockLatency.zero
  public static let previewValue = MockLatency.between(.milliseconds(300) ... .milliseconds(800))
}

extension DependencyValues {
  public var mockLatency: MockLatency {
    get { self[MockLatency.self] }
    set { self[MockLatency.self] = newValue }
  }
}
