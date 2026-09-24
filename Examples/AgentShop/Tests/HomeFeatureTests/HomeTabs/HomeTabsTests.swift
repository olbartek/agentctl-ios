import AgentCtlCore
import ComposableArchitecture
import Foundation
import HomeFeature
import Models
import OrdersClient
import Testing

@MainActor
@Suite(.serialized)
struct HomeTabsTests {
  let alice = Session(user: User(id: "u1", name: "Alice", email: "alice@example.com"), token: "t")
  let homeID = UUID(0)

  @Test func switchingTabs() async {
    let store = TestStore(initialState: HomeTabs.State(id: homeID, session: alice)) { HomeTabs() }
    await store.send(.tabSelected(.profile)) { $0.selectedTab = .profile }
    await store.send(.tabSelected(.orders)) { $0.selectedTab = .orders }
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

  @Test func agentScreens() throws {
    var state = HomeTabs.State(id: homeID, session: alice)
    let list = HomeTabs.activeScreen(state)
    #expect(list.path == "home/orders")
    #expect(list.commands.map(\.name) == ["open", "refresh", "retry", "tab"])
    #expect(try list.command(named: "tab")?.makeAction("profile") != nil)
    #expect(throws: AgentCommandError.invalidArgument("expected orders|profile")) {
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
    #expect(HomeTabs.registry.map(\.path) == ["home/orders", "home/orders/<id>", "home/profile"])
    #expect(HomeTabs.registry[1].commands.map(\.name) == ["cancel", "retry", "tab", "back"])
  }
}
