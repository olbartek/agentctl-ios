import AgentCtlCore
import ComposableArchitecture
import Foundation
import HomeFeature
import Models
import OrdersClient
import ShopFeature
import CatalogClient
import Testing

@MainActor
@Suite(.serialized)
struct HomeTabsTests {
  let alice = Session(user: User(id: "u1", name: "Alice", email: "alice@example.com"), token: "t")
  let homeID = UUID(0)

  @Test func switchingTabs() async {
    let store = TestStore(initialState: HomeTabs.State(id: homeID, session: alice)) { HomeTabs() }
    #expect(store.state.selectedTab == .shop)
    await store.send(.tabSelected(.profile)) { $0.selectedTab = .profile }
    await store.send(.tabSelected(.orders)) { $0.selectedTab = .orders }
  }

  @Test func selectingTheSelectedTabAgainPopsItToItsFirstScreen() async {
    let store = TestStore(
      initialState: HomeTabs.State(
        id: homeID,
        session: alice,
        selectedTab: .orders,
        ordersPath: StackState([.detail(OrderDetail.State(orderID: 1003))])
      )
    ) {
      HomeTabs()
    }
    await store.send(.tabSelected(.orders)) { $0.ordersPath = StackState() }
  }

  @Test func openingAnOrderPushesItsDetailAndBackPopsIt() async {
    let store = TestStore(initialState: HomeTabs.State(id: homeID, session: alice)) { HomeTabs() }
    await store.send(.ordersList(.orderTapped(1003)))
    await store.receive(\.ordersList.delegate.openOrder) {
      $0.ordersPath[id: 0] = .detail(OrderDetail.State(orderID: 1003))
    }
    await store.send(.ordersPath(.popFrom(id: 0))) { $0.ordersPath = StackState() }
  }

  @Test func cancellingInTheDetailUpdatesTheList() async {
    let orders = MockOrders.alice
    var cancelled = orders[2]
    cancelled.status = .cancelled
    let store = TestStore(
      initialState: HomeTabs.State(
        id: homeID,
        session: alice,
        ordersList: OrdersList.State(orders: IdentifiedArray(uniqueElements: orders), hasLoaded: true),
        ordersPath: StackState([.detail(OrderDetail.State(orderID: 1003, order: cancelled))])
      )
    ) {
      HomeTabs()
    }
    await store.send(.ordersPath(.element(id: 0, action: .detail(.delegate(.orderCancelled(cancelled))))))
    await store.receive(\.ordersList.orderUpdated) {
      $0.ordersList.orders[id: 1003]?.status = .cancelled
    }
  }

  @Test func loggingOutIsForwarded() async {
    let store = TestStore(initialState: HomeTabs.State(id: homeID, session: alice)) { HomeTabs() }
    await store.send(.profile(.delegate(.loggedOut)))
    await store.receive(\.delegate.loggedOut)
  }

  @Test func addingFromAProductFillsTheCartAndPlacingAnOrderEmptiesIt() async {
    let store = TestStore(initialState: HomeTabs.State(id: homeID, session: alice)) { HomeTabs() }
    let runner = Catalog.products[0]
    await store.send(.shop(.delegate(.openProduct(runner)))) {
      $0.shopPath[id: 0] = .product(ProductDetail.State(product: runner))
    }
    let line = CartLine(product: runner, size: "42", quantity: 1)
    await store.send(.shopPath(.element(id: 0, action: .product(.delegate(.add(line))))))
    await store.receive(\.cart.add) { $0.cart.lines = [line] }
    await store.send(.shopPath(.element(id: 0, action: .product(.delegate(.viewCart))))) { $0.selectedTab = .cart }
    await store.send(.cart(.delegate(.checkout))) {
      $0.cartPath[id: 1] = .checkout(Checkout.State(lines: [line]))
    }
    let order = Order(id: 1004, status: .pending, placedOn: day("2026-01-01"), items: [])
    await store.send(.cartPath(.element(id: 1, action: .checkout(.delegate(.placed(order)))))) {
      $0.cartPath[id: 2] = .confirmation(OrderConfirmation.State(order: order))
    }
    await store.receive(\.cart.emptied) { $0.cart = Cart.State() }
    await store.receive(\.ordersList.orderUpdated) { $0.ordersList.orders[id: 1004] = order }
    await store.send(.cartPath(.element(id: 2, action: .confirmation(.delegate(.viewOrder(1004)))))) {
      $0.cartPath = StackState()
      $0.selectedTab = .orders
      $0.ordersPath[id: 3] = .detail(OrderDetail.State(orderID: 1004))
    }
  }

  @Test func agentScreens() throws {
    var state = HomeTabs.State(id: homeID, session: alice)
    #expect(HomeTabs.activeScreen(state).path == "home/shop")
    state.selectedTab = .orders
    let list = HomeTabs.activeScreen(state)
    #expect(list.path == "home/orders")
    #expect(list.commands.map(\.name) == ["open", "refresh", "retry", "tab"])
    #expect(try list.command(named: "tab")?.makeAction("profile") != nil)
    #expect(throws: AgentCommandError.invalidArgument("expected shop|cart|orders|profile")) {
      try list.command(named: "tab")?.makeAction("settings")
    }

    state.ordersPath.append(.detail(OrderDetail.State(orderID: 1003)))
    let detail = HomeTabs.activeScreen(state)
    #expect(detail.path == "home/orders/1003")
    #expect(detail.commands.map(\.name) == ["cancel", "retry", "tab", "back"])
    #expect(detail.identity.hasPrefix("home#\(homeID.uuidString)/"))

    state.selectedTab = .profile
    let profile = HomeTabs.activeScreen(state)
    #expect(profile.path == "home/profile")
    #expect(profile.command(named: "back") == nil)
  }

  @Test func registry() {
    #expect(
      HomeTabs.registry.map(\.path) == [
        "home/shop", "home/shop/<sku>", "home/cart", "home/cart/checkout", "home/cart/confirmation",
        "home/orders", "home/orders/<id>", "home/profile",
      ]
    )
    #expect(HomeTabs.registry[6].commands.map(\.name) == ["cancel", "retry", "tab", "back"])
  }
}
