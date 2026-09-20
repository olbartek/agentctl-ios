import Dependencies
import Synchronization

/// Records every mock call as `"<client>.<method>"`, e.g. `items.fetch`, and how many are still running.
///
/// Agents see the entries as `calls=` in step summaries and assert on them with `expect call=…`.
/// AgentBridge waits for `inFlight == 0` when settling a step in the running app.
public final class MockCallLog: Sendable {
  private struct Storage {
    var entries: [String] = []
    var inFlight = 0
  }

  private let storage = Mutex(Storage())

  public init() {}

  public func begin(_ name: String) {
    storage.withLock {
      $0.entries.append(name)
      $0.inFlight += 1
    }
  }

  public func end(_ name: String) {
    storage.withLock { $0.inFlight -= 1 }
  }

  public var entries: [String] { storage.withLock(\.entries) }
  public var count: Int { storage.withLock(\.entries.count) }
  public var inFlight: Int { storage.withLock(\.inFlight) }

  /// Entries recorded after the first `index` entries.
  public func entries(since index: Int) -> [String] {
    storage.withLock { Array($0.entries.dropFirst(index)) }
  }
}

extension MockCallLog: DependencyKey {
  public static let liveValue = MockCallLog()
  public static var testValue: MockCallLog { MockCallLog() }
}

extension DependencyValues {
  public var mockCallLog: MockCallLog {
    get { self[MockCallLog.self] }
    set { self[MockCallLog.self] = newValue }
  }
}
