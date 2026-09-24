import AgentCtlCore
import ComposableArchitecture
import HomeFeature
import Models
import OrdersClient
import Testing

@MainActor
@Suite(.serialized)
struct OrdersListTests {
  let orders = MockOrders.alice

  @Test func firstAppearanceLoadsOnce() async {
    let orders = orders
    let store = TestStore(initialState: OrdersList.State()) {
      OrdersList()
    } withDependencies: {
      $0.ordersClient.fetchOrders = { orders }
    }
    #expect(store.state.phase == .loading)
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.ordersResponse.success) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.orders = IdentifiedArray(uniqueElements: orders)
    }
    #expect(store.state.phase == .loaded)
    await store.send(.onAppear)
  }

  @Test func emptyList() async {
    let store = TestStore(initialState: OrdersList.State()) {
      OrdersList()
    } withDependencies: {
      $0.ordersClient.fetchOrders = { [] }
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.ordersResponse.success) {
      $0.isLoading = false
      $0.hasLoaded = true
    }
    #expect(store.state.phase == .empty)
  }

  @Test func failureThenRetry() async {
    let orders = orders
    let attempts = LockIsolated(0)
    let store = TestStore(initialState: OrdersList.State()) {
      OrdersList()
    } withDependencies: {
      $0.ordersClient.fetchOrders = {
        attempts.withValue { $0 += 1 }
        if attempts.value == 1 { throw OrdersError.network }
        return orders
      }
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.ordersResponse.failure, .network) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.error = .network
    }
    #expect(store.state.phase == .failed)
    await store.send(.retry) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.ordersResponse.success) {
      $0.isLoading = false
      $0.orders = IdentifiedArray(uniqueElements: orders)
    }
  }

  @Test func refreshKeepsRowsAndReportsErrors() async {
    let store = TestStore(initialState: OrdersList.State(orders: IdentifiedArray(uniqueElements: orders), hasLoaded: true)) {
      OrdersList()
    } withDependencies: {
      $0.ordersClient.fetchOrders = { throw OrdersError.network }
    }
    await store.send(.refresh) { $0.isLoading = true }
    await store.receive(\.ordersResponse.failure, .network) {
      $0.isLoading = false
      $0.error = .network
    }
    #expect(store.state.phase == .loaded)
  }

  @Test func tappingAnOrderAsksToOpenIt() async {
    let store = TestStore(initialState: OrdersList.State()) { OrdersList() }
    await store.send(.orderTapped(1003))
    await store.receive(\.delegate.openOrder, 1003)
  }

  @Test func orderUpdatesReplaceTheRow() async {
    var cancelled = orders[2]
    cancelled.status = .cancelled
    let store = TestStore(initialState: OrdersList.State(orders: IdentifiedArray(uniqueElements: orders), hasLoaded: true)) {
      OrdersList()
    }
    await store.send(.orderUpdated(cancelled)) { $0.orders[id: 1003]?.status = .cancelled }
  }

  @Test func agentSummaryAndCommands() throws {
    let loaded = OrdersList.activeScreen(OrdersList.State(orders: IdentifiedArray(uniqueElements: orders), hasLoaded: true))
    #expect(loaded.summary == [SummaryItem("orders", 3), SummaryItem("loading", false), SummaryItem("statuses", "delivered,shipped,pending")])
    #expect(loaded.command(named: "retry")?.disabledReason == "error=none")
    #expect(throws: AgentCommandError.invalidArgument("expected an order id such as 1003")) {
      try loaded.command(named: "open")?.makeAction("abc")
    }
    #expect(loaded.appearAction != nil)
  }
}
