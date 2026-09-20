import Dependencies
import Synchronization

/// One-shot forced failures keyed by `"<client>.<method>"`.
///
/// `mock <client.method> <error>` registers `<error>` for `<client.method>`; the next call to that
/// method throws the matching error and the fault is cleared.
public final class MockFaults: Sendable {
  private let faults = Mutex([String: String]())

  public init() {}

  public func set(_ method: String, code: String) {
    faults.withLock { $0[method] = code }
  }

  /// Returns and clears the fault registered for `method`, if any.
  public func take(_ method: String) -> String? {
    faults.withLock { $0.removeValue(forKey: method) }
  }

  public var pending: [String: String] { faults.withLock { $0 } }
}

extension MockFaults: DependencyKey {
  public static let liveValue = MockFaults()
  public static var testValue: MockFaults { MockFaults() }
}

extension DependencyValues {
  public var mockFaults: MockFaults {
    get { self[MockFaults.self] }
    set { self[MockFaults.self] = newValue }
  }
}
