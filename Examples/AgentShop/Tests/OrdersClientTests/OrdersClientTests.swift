import AgentCtlCore
import ComposableArchitecture
import Models
import OrdersClient
import SessionClient
import Testing

struct OrdersBackendTests {
  @Test func seededOrders() async {
    let backend = OrdersBackend()
    let orders = await backend.orders(for: "alice@example.com")
    #expect(orders.map(\.id) == [1001, 1002, 1003])
    #expect(orders.map(\.status) == [.delivered, .shipped, .pending])
    #expect(orders.map { formatCents($0.totalCents) } == ["$43.99", "$89.00", "$59.80"])
    #expect(await backend.orders(for: "bob@example.com").isEmpty)
  }

  @Test func fetchOne() async throws {
    let backend = OrdersBackend()
    #expect(try await backend.order(id: 1002, for: "alice@example.com").status == .shipped)
    await #expect(throws: OrdersError.notFound) { try await backend.order(id: 9999, for: "alice@example.com") }
    await #expect(throws: OrdersError.notFound) { try await backend.order(id: 1001, for: "bob@example.com") }
  }

  @Test func cancel() async throws {
    let backend = OrdersBackend()
    let cancelled = try await backend.cancelOrder(id: 1003, for: "alice@example.com")
    #expect(cancelled.status == .cancelled)
    #expect(try await backend.order(id: 1003, for: "alice@example.com").status == .cancelled)
    await #expect(throws: OrdersError.notCancellable) { try await backend.cancelOrder(id: 1003, for: "alice@example.com") }
    await #expect(throws: OrdersError.notCancellable) { try await backend.cancelOrder(id: 1002, for: "alice@example.com") }
    await #expect(throws: OrdersError.notFound) { try await backend.cancelOrder(id: 9999, for: "alice@example.com") }
  }
}

struct OrdersClientLiveTests {
  let alice = Session(user: User(id: "u1", name: "Alice", email: "alice@example.com"), token: "mock-token-u1")

  @Test func usesTheSignedInUserWithoutLoggingASessionCall() async throws {
    let log = MockCallLog()
    try await withDependencies {
      $0.mockCallLog = log
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
      $0.sessionStorage = .inMemory(StoredSession(session: alice, remember: true))
      $0.ordersBackend = OrdersBackend()
    } operation: {
      let client = OrdersClient.liveValue
      let orders = try await client.fetchOrders()
      let first = try await client.fetchOrder(1001)
      let cancelled = try await client.cancelOrder(1003)
      #expect(orders.count == 3)
      #expect(first.status == .delivered)
      #expect(cancelled.status == .cancelled)
    }
    #expect(log.entries == ["orders.fetchOrders", "orders.fetchOrder", "orders.cancelOrder"])
  }

  @Test func signedOutIsUnauthorized() async {
    await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
      $0.sessionStorage = .inMemory()
      $0.ordersBackend = OrdersBackend()
    } operation: {
      await #expect(throws: OrdersError.unauthorized) { try await OrdersClient.liveValue.fetchOrders() }
    }
  }

  @Test func faults() async throws {
    let faults = MockFaults()
    faults.set("orders.fetchOrders", code: "network")
    faults.set("orders.cancelOrder", code: "notCancellable")
    try await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = faults
      $0.mockLatency = .zero
      $0.sessionStorage = .inMemory(StoredSession(session: alice, remember: true))
      $0.ordersBackend = OrdersBackend()
    } operation: {
      await #expect(throws: OrdersError.network) { try await OrdersClient.liveValue.fetchOrders() }
      await #expect(throws: OrdersError.notCancellable) { try await OrdersClient.liveValue.cancelOrder(1003) }
      let orders = try await OrdersClient.liveValue.fetchOrders()
      #expect(orders.count == 3)
    }
  }

  @Test func mockMethods() {
    #expect(OrdersClient.mockMethods.map(\.name) == ["orders.fetchOrders", "orders.fetchOrder", "orders.cancelOrder"])
  }
}
