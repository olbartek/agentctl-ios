import Dependencies

/// Wraps a clock and counts the sleeps currently waiting on it.
///
/// The count is `pending` in step summaries: effects waiting for time to pass, such as a countdown before a
/// button becomes available again. Headlessly, `advance` releases them. Counting sleeps (rather than all
/// in-flight effects) keeps long-lived effects that TCA starts for navigation out of the number.
public struct CountingClock<Base: Clock>: Clock where Base.Duration == Duration {
  public typealias Instant = Base.Instant

  public let base: Base
  private let sleeps: Sleeps

  public init(_ base: Base) {
    self.base = base
    self.sleeps = Sleeps()
  }

  /// Sleeps in progress right now.
  public var activeSleeps: Int { sleeps.count }

  /// The earliest deadline among the sleeps in progress, `nil` when there are none. Headlessly, `wait` moves the
  /// clock from one to the next (CONTRACT.md §2.5).
  public var earliestDeadline: Instant? { sleeps.earliest }

  public var now: Instant { base.now }
  public var minimumResolution: Duration { base.minimumResolution }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = sleeps.add(deadline)
    defer { sleeps.remove(id) }
    try await base.sleep(until: deadline, tolerance: tolerance)
  }

  final class Sleeps: Sendable {
    private let state = Locked((next: 0, deadlines: [Int: Instant]()))
    var count: Int { state.withLock { $0.deadlines.count } }
    var earliest: Instant? { state.withLock { $0.deadlines.values.min() } }

    func add(_ deadline: Instant) -> Int {
      state.withLock { state in
        state.next += 1
        state.deadlines[state.next] = deadline
        return state.next
      }
    }

    func remove(_ id: Int) {
      state.withLock { _ = $0.deadlines.removeValue(forKey: id) }
    }
  }
}
