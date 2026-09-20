import AgentCtlCore
import ComposableArchitecture
import Testing

struct MockingTests {
  struct Boom: Error, Equatable {
    var code: String
  }

  @Test func callLogRecordsEntriesAndInFlight() {
    let log = MockCallLog()
    log.begin("auth.login")
    #expect(log.inFlight == 1)
    log.begin("session.save")
    log.end("session.save")
    log.end("auth.login")
    #expect(log.entries == ["auth.login", "session.save"])
    #expect(log.inFlight == 0)
    #expect(log.entries(since: 1) == ["session.save"])
    #expect(log.count == 2)
  }

  @Test func faultsAreOneShot() {
    let faults = MockFaults()
    faults.set("orders.fetchOrders", code: "network")
    #expect(faults.pending == ["orders.fetchOrders": "network"])
    #expect(faults.take("orders.fetchOrders") == "network")
    #expect(faults.take("orders.fetchOrders") == nil)
  }

  @Test func latencySampling() {
    let generator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
    #expect(MockLatency.zero.sample(using: generator) == .zero)
    #expect(MockLatency.fixed(.milliseconds(300)).sample(using: generator) == .milliseconds(300))
    for _ in 0..<20 {
      let delay = MockLatency.between(.milliseconds(300) ... .milliseconds(800)).sample(using: generator)
      #expect(delay >= .milliseconds(300) && delay <= .milliseconds(800))
    }
    #expect(MockLatency.milliseconds(0) == .zero)
  }

  @Test func mockCallWithZeroLatencyNeverTouchesTheClock() async throws {
    let log = MockCallLog()
    let value = try await withDependencies {
      $0.mockCallLog = log
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
      $0.continuousClock = UnimplementedClock()
    } operation: {
      try await mockCall("demo.fetch", error: { Boom(code: $0) }) { 42 }
    }
    #expect(value == 42)
    #expect(log.entries == ["demo.fetch"])
    #expect(log.inFlight == 0)
  }

  @Test func mockCallThrowsTheRegisteredFaultOnce() async throws {
    let faults = MockFaults()
    faults.set("demo.fetch", code: "network")
    try await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = faults
      $0.mockLatency = .zero
    } operation: {
      await #expect(throws: Boom(code: "network")) {
        try await mockCall("demo.fetch", error: { Boom(code: $0) }) { 1 }
      }
      let second = try await mockCall("demo.fetch", error: { Boom(code: $0) }) { 2 }
      #expect(second == 2)
    }
  }

  @Test @MainActor func mockCallWithLatencySleepsOnTheInjectedClock() async throws {
    try await withMainSerialExecutor {
      let clock = TestClock()
      let log = MockCallLog()
      let task = Task {
        try await withDependencies {
          $0.mockCallLog = log
          $0.mockFaults = MockFaults()
          $0.mockLatency = .fixed(.milliseconds(500))
          $0.continuousClock = clock
        } operation: {
          try await mockCall("demo.fetch", error: { Boom(code: $0) }) { "done" }
        }
      }
      await clock.advance(by: .milliseconds(499))
      #expect(log.inFlight == 1)
      await clock.advance(by: .milliseconds(1))
      let value = try await task.value
      #expect(value == "done")
      #expect(log.inFlight == 0)
    }
  }
}
