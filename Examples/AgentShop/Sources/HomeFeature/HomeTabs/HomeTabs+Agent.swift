import AgentCtlCore
import ComposableArchitecture
import ShopFeature

extension HomeTabs: AgentContainer {
  static let backHelp = "Go back to the previous screen."
  static let tabHelp = "Switch tab."

  /// `tab` on every screen of every tab, pushed or not.
  public static let inheritedCommands: [AgentCommand<State, Action>] = [
    .choice("tab", of: Tab.self, help: tabHelp) { .tabSelected($0) }
  ]

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    var commands: [ResolvedCommand<Action>] = []
    func back(_ action: Action) {
      commands.append(AgentCommand<State, Action>.action("back", help: backHelp, action).resolve(state, source: "HomeTabs"))
    }
    let screen: ActiveScreen<Action>
    switch state.selectedTab {
    case .shop:
      if let id = state.shopPath.ids.last, let top = state.shopPath[id: id] {
        switch top {
        case let .product(product):
          screen = ProductDetail.activeScreen(product)
            .map { .shopPath(.element(id: id, action: .product($0))) }
            .identified(by: id.debugDescription)
        }
        back(.shopPath(.popFrom(id: id)))
      } else {
        screen = ShopFeed.activeScreen(state.shop).map { .shop($0) }
      }
    case .cart:
      if let id = state.cartPath.ids.last, let top = state.cartPath[id: id] {
        switch top {
        case let .checkout(checkout):
          screen = Checkout.activeScreen(checkout)
            .map { .cartPath(.element(id: id, action: .checkout($0))) }
            .identified(by: id.debugDescription)
          back(.cartPath(.popFrom(id: id)))
        case let .confirmation(confirmation):
          // The order is placed: there is no going back to checkout.
          screen = OrderConfirmation.activeScreen(confirmation)
            .map { .cartPath(.element(id: id, action: .confirmation($0))) }
            .identified(by: id.debugDescription)
        }
      } else {
        screen = Cart.activeScreen(state.cart).map { .cart($0) }
      }
    case .orders:
      if let id = state.ordersPath.ids.last, let top = state.ordersPath[id: id] {
        switch top {
        case let .detail(detail):
          screen = OrderDetail.activeScreen(detail)
            .map { .ordersPath(.element(id: id, action: .detail($0))) }
            .identified(by: id.debugDescription)
        }
        back(.ordersPath(.popFrom(id: id)))
      } else {
        screen = OrdersList.activeScreen(state.ordersList).map { .ordersList($0) }
      }
    case .profile:
      screen = Profile.activeScreen(state.profile).map { .profile($0) }
    }
    return inheritingCommands(screen.identified(by: "home#\(state.id.uuidString)"), state).appending(commands)
  }

  public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "HomeTabs")
    // `back` is ours too, so `inheritingCommands` puts `tab` before it, as on the active screen.
    return inheritingCommands(
      ShopFeed.screenDocs
        + ProductDetail.screenDocs.map { $0.inheriting([back]) }
        + Cart.screenDocs
        + Checkout.screenDocs.map { $0.inheriting([back]) }
        + OrderConfirmation.screenDocs
        + OrdersList.screenDocs
        + OrderDetail.screenDocs.map { $0.inheriting([back]) }
        + Profile.screenDocs
    )
  }
}
