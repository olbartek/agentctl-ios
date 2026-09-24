import AgentCtlCore
import Dependencies
import Models
import Testing

struct ScheduledFaultsTests {
  @Test func firesOnTheScheduledCallOnly() {
    let faults = ScheduledFaults(arguments: ["AgentShop", "-mock-fault", "orders.fetchOrders#2=network"])
    #expect(faults.next("orders.fetchOrders") == nil)
    #expect(faults.next("orders.fetchOrders") == "network")
    #expect(faults.next("orders.fetchOrders") == nil)
  }

  @Test func countsEachMethodSeparately() {
    let faults = ScheduledFaults(arguments: ["-mock-fault", "a.one#1=timeout", "-mock-fault", "a.two#2=network"])
    #expect(faults.next("a.two") == nil)
    #expect(faults.next("a.one") == "timeout")
    #expect(faults.next("a.two") == "network")
  }

  @Test(arguments: ["a.one=network", "a.one#x=network", "a.one#1", "#1=network"])
  func ignoresMalformedSpecs(_ spec: String) {
    let faults = ScheduledFaults(arguments: ["-mock-fault", spec])
    #expect(faults.next("a.one") == nil)
    #expect(faults.next("") == nil)
  }

  @Test func ignoresOtherArguments() {
    let faults = ScheduledFaults(arguments: ["-agent-port", "0", "-mock-fault"])
    #expect(faults.next("-agent-port") == nil)
  }

  struct Failure: Error, Equatable { var code: String }

  @Test func shopCallArmsTheFaultForThatCall() async throws {
    try await withDependencies {
      $0.scheduledFaults = ScheduledFaults(arguments: ["-mock-fault", "a.one#2=network"])
      $0.mockFaults = MockFaults()
      $0.mockCallLog = MockCallLog()
      $0.mockLatency = .zero
    } operation: {
      let call: @Sendable () async throws -> Int = {
        try await shopCall("a.one", error: { Failure(code: $0) }) { 42 }
      }
      let first = try await call()
      #expect(first == 42)
      await #expect(throws: Failure(code: "network")) { try await call() }
      let third = try await call()
      #expect(third == 42)
    }
  }
}
