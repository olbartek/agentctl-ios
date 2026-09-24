import AgentCtlCore
import Dependencies
import Synchronization

/// Backend failures scheduled at launch, for XCUITests.
///
/// A UI test cannot type `mock orders.fetchOrders network` the way a script can, so it passes a launch argument
/// instead: `-mock-fault orders.fetchOrders#2=network` makes the *second* call to `orders.fetchOrders` fail with
/// `network`. The call index is what lets a fault land on the call a scenario meant: `bench/gen_uitests.py`
/// derives it from the calls the same scenario made headlessly. Headless runs and the agent bridge use `mock`
/// and leave this empty.
public final class ScheduledFaults: Sendable {
  private struct State {
    var plan: [String: [Int: String]] = [:]
    var counts: [String: Int] = [:]
  }

  private let state: Mutex<State>

  public init(arguments: [String] = []) {
    var state = State()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      guard argument == "-mock-fault", let spec = iterator.next() else { continue }
      let parts = spec.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let target = parts[0].split(separator: "#")
      guard target.count == 2, let index = Int(target[1]), !target[0].isEmpty else { continue }
      state.plan[String(target[0]), default: [:]][index] = String(parts[1])
    }
    self.state = Mutex(state)
  }

  /// Counts one call to `method` and returns the error code scheduled for it, if any.
  public func next(_ method: String) -> String? {
    state.withLock { state in
      let count = state.counts[method, default: 0] + 1
      state.counts[method] = count
      return state.plan[method]?[count]
    }
  }
}

extension ScheduledFaults: DependencyKey {
  public static let liveValue = ScheduledFaults()
  public static var testValue: ScheduledFaults { ScheduledFaults() }
}

extension DependencyValues {
  public var scheduledFaults: ScheduledFaults {
    get { self[ScheduledFaults.self] }
    set { self[ScheduledFaults.self] = newValue }
  }
}

/// The one shim every AgentShop client method goes through: it arms a fault scheduled for this call (see
/// ``ScheduledFaults``), then hands over to AgentCtl's `mockCall`, which logs the call, waits the mock latency
/// and throws a fault armed by `mock`.
public func shopCall<T: Sendable>(
  _ name: String,
  error makeError: @Sendable (String) -> any Error,
  _ body: @Sendable () async throws -> T
) async throws -> T {
  @Dependency(\.scheduledFaults) var scheduled
  @Dependency(\.mockFaults) var faults
  if let code = scheduled.next(name) {
    faults.set(name, code: code)
  }
  return try await mockCall(name, error: makeError, body)
}
