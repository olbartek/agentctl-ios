import AgentCtlCore
import ComposableArchitecture
import HomeFeature
import Models
import OrdersClient
import Testing

@MainActor
@Suite(.serialized)
struct OrderDetailTests {
  let pending = MockOrders.alice[2]
  let shipped = MockOrders.alice[1]

  @Test func loadsOnAppearance() async {
    let pending = pending
    let store = TestStore(initialState: OrderDetail.State(orderID: 1003)) {
      OrderDetail()
    } withDependencies: {
      $0.ordersClient.fetchOrder = { id in
        guard id == 1003 else { throw OrdersError.notFound }
        return pending
      }
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.orderResponse.success) {
      $0.isLoading = false
      $0.order = pending
    }
    #expect(store.state.canCancel)
    await store.send(.onAppear)
  }

  @Test(arguments: [OrdersError.notFound, .network])
  func loadFailures(_ error: OrdersError) async {
    let store = TestStore(initialState: OrderDetail.State(orderID: 9999)) {
      OrderDetail()
    } withDependencies: {
      $0.ordersClient.fetchOrder = { _ in throw error }
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.orderResponse.failure, error) {
      $0.isLoading = false
      $0.error = error
    }
    #expect(!store.state.canCancel)
  }

  @Test func retryAfterAFailure() async {
    let pending = pending
    let store = TestStore(initialState: OrderDetail.State(orderID: 1003, error: .network)) {
      OrderDetail()
    } withDependencies: {
      $0.ordersClient.fetchOrder = { _ in pending }
    }
    await store.send(.retry) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.orderResponse.success) {
      $0.isLoading = false
      $0.order = pending
    }
  }

  @Test func cancellingAPendingOrder() async {
    var cancelled = pending
    cancelled.status = .cancelled
    let result = cancelled
    let store = TestStore(initialState: OrderDetail.State(orderID: 1003, order: pending)) {
      OrderDetail()
    } withDependencies: {
      $0.ordersClient.cancelOrder = { _ in result }
    }
    await store.send(.cancelTapped) { $0.isCancelling = true }
    await store.receive(\.cancelResponse.success) {
      $0.isCancelling = false
      $0.order = result
    }
    await store.receive(\.delegate.orderCancelled, result)
    #expect(!store.state.canCancel)
  }

  @Test(arguments: [OrdersError.notCancellable, .network])
  func cancelFailures(_ error: OrdersError) async {
    let store = TestStore(initialState: OrderDetail.State(orderID: 1003, order: pending)) {
      OrderDetail()
    } withDependencies: {
      $0.ordersClient.cancelOrder = { _ in throw error }
    }
    await store.send(.cancelTapped) { $0.isCancelling = true }
    await store.receive(\.cancelResponse.failure, error) {
      $0.isCancelling = false
      $0.error = error
    }
  }

  @Test func onlyPendingOrdersCanBeCancelled() async {
    let store = TestStore(initialState: OrderDetail.State(orderID: 1002, order: shipped)) { OrderDetail() }
    #expect(!store.state.canCancel)
    await store.send(.cancelTapped)
  }

  @Test func agentSummary() {
    let screen = OrderDetail.activeScreen(OrderDetail.State(orderID: 1003, order: pending))
    #expect(screen.path == "home/orders/1003")
    #expect(
      screen.summary == [
        SummaryItem("id", 1003), SummaryItem("status", "pending"), SummaryItem("items", 2),
        SummaryItem("total", "$59.80"), SummaryItem("date", "2025-12-30"), SummaryItem("canCancel", true),
        SummaryItem("loading", false),
      ]
    )
    let loading = OrderDetail.activeScreen(OrderDetail.State(orderID: 1001, isLoading: true))
    #expect(loading.summary.map(\.key) == ["id", "canCancel", "loading"])
  }
}
