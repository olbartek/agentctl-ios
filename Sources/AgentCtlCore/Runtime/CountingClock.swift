import Dependencies
import Synchronization

/// Wraps a clock and counts the sleeps currently waiting on it.
///
/// The count is `pending` in step summaries: effects waiting for time to pass, such as the OTP resend
/// countdown. Headlessly, `advance` releases them. Counting sleeps (rather than all in-flight effects) keeps
/// long-lived effects that TCA starts for navigation out of the number.
public struct CountingClock<Base: Clock>: Clock where Base.Duration == Duration {
  public typealias Instant = Base.Instant

  public let base: Base
  private let counter: Counter

  public init(_ base: Base) {
    self.base = base
    self.counter = Counter()
  }

  /// Sleeps in progress right now.
  public var activeSleeps: Int { counter.value }

  public var now: Instant { base.now }
  public var minimumResolution: Duration { base.minimumResolution }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    counter.increment()
    defer { counter.decrement() }
    try await base.sleep(until: deadline, tolerance: tolerance)
  }

  final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
    func decrement() { count.withLock { $0 -= 1 } }
  }
}
