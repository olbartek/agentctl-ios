import AgentCtlCore
import ComposableArchitecture
import ShopFeature

extension HomeTabs: AgentContainer {
  static let backHelp = "Go back to the previous screen."
  static let tabHelp = "Switch tab."
  static let tabs = Tab.allCases.map(\.rawValue).joined(separator: "|")

  static let tabCommand = AgentCommand<State, Action>.parsing(
    "tab",
    argument: "<\(tabs)>",
    help: tabHelp
  ) { text throws(AgentCommandError) in
    guard let tab = Tab(rawValue: text) else { throw .invalidArgument("expected \(tabs)") }
    return .tabSelected(tab)
  }

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    var commands = [tabCommand.resolve(state, source: "HomeTabs")]
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
    return screen.identified(by: "home#\(state.id.uuidString)").appending(commands)
  }

  public static var registry: [ScreenDoc] {
    let tab = CommandDoc(name: "tab", argument: "<\(tabs)>", help: tabHelp, source: "HomeTabs")
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "HomeTabs")
    return ShopFeed.screenDocs.map { $0.inheriting([tab]) }
      + ProductDetail.screenDocs.map { $0.inheriting([tab, back]) }
      + Cart.screenDocs.map { $0.inheriting([tab]) }
      + Checkout.screenDocs.map { $0.inheriting([tab, back]) }
      + OrderConfirmation.screenDocs.map { $0.inheriting([tab]) }
      + OrdersList.screenDocs.map { $0.inheriting([tab]) }
      + OrderDetail.screenDocs.map { $0.inheriting([tab, back]) }
      + Profile.screenDocs.map { $0.inheriting([tab]) }
  }
}
