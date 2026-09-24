import ComposableArchitecture
import Foundation
import Models
import ShopFeature

/// The signed-in area, four tabs:
/// - shop: the feed, with a product pushed on top;
/// - cart: the cart, with checkout and then the order confirmation pushed on top;
/// - orders: the list, with an order's detail pushed on top;
/// - profile.
///
/// The cart lives here rather than in its tab, because the product screen in the shop tab adds to it.
@Reducer
public struct HomeTabs {
  public enum Tab: String, CaseIterable, Equatable, Sendable {
    case shop
    case cart
    case orders
    case profile
  }

  @Reducer
  public enum ShopPath {
    case product(ProductDetail)
  }

  @Reducer
  public enum CartPath {
    case checkout(Checkout)
    case confirmation(OrderConfirmation)
  }

  @Reducer
  public enum OrdersPath {
    case detail(OrderDetail)
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    /// Identifies this signed-in session's home. A new id means a fresh home, so the UI (and the headless
    /// runtime) treats its screens as newly appeared.
    public var id: UUID
    public var selectedTab: Tab
    public var shop: ShopFeed.State
    public var shopPath: StackState<ShopPath.State>
    public var cart: Cart.State
    public var cartPath: StackState<CartPath.State>
    public var ordersList: OrdersList.State
    public var ordersPath: StackState<OrdersPath.State>
    public var profile: Profile.State

    public init(
      id: UUID,
      session: Session,
      selectedTab: Tab = .shop,
      shop: ShopFeed.State = ShopFeed.State(),
      shopPath: StackState<ShopPath.State> = StackState(),
      cart: Cart.State = Cart.State(),
      cartPath: StackState<CartPath.State> = StackState(),
      ordersList: OrdersList.State = OrdersList.State(),
      ordersPath: StackState<OrdersPath.State> = StackState()
    ) {
      self.id = id
      self.selectedTab = selectedTab
      self.shop = shop
      self.shopPath = shopPath
      self.cart = cart
      self.cartPath = cartPath
      self.ordersList = ordersList
      self.ordersPath = ordersPath
      self.profile = Profile.State(user: session.user)
    }
  }

  public enum Action: Sendable {
    case tabSelected(Tab)
    case shop(ShopFeed.Action)
    case shopPath(StackActionOf<ShopPath>)
    case cart(Cart.Action)
    case cartPath(StackActionOf<CartPath>)
    case ordersList(OrdersList.Action)
    case ordersPath(StackActionOf<OrdersPath>)
    case profile(Profile.Action)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case loggedOut
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.shop, action: \.shop) { ShopFeed() }
    Scope(state: \.cart, action: \.cart) { Cart() }
    Scope(state: \.ordersList, action: \.ordersList) { OrdersList() }
    Scope(state: \.profile, action: \.profile) { Profile() }
    Reduce { state, action in
      switch action {
      case let .tabSelected(tab):
        state.selectedTab = tab
        return .none

      case let .shop(.delegate(.openProduct(product))):
        state.shopPath.append(.product(ProductDetail.State(product: product)))
        return .none

      case let .shopPath(.element(_, .product(.delegate(.add(line))))):
        return .send(.cart(.add(line)))

      case .shopPath(.element(_, .product(.delegate(.viewCart)))):
        state.selectedTab = .cart
        return .none

      case .cart(.delegate(.checkout)):
        state.cartPath.append(
          .checkout(Checkout.State(lines: Array(state.cart.lines), discountCents: state.cart.discountCents))
        )
        return .none

      case let .cartPath(.element(_, .checkout(.delegate(.placed(order))))):
        state.cartPath.append(.confirmation(OrderConfirmation.State(order: order)))
        return .merge(.send(.cart(.emptied)), .send(.ordersList(.orderUpdated(order))))

      case let .cartPath(.element(_, .confirmation(.delegate(.viewOrder(id))))):
        state.cartPath.removeAll()
        state.selectedTab = .orders
        state.ordersPath.removeAll()
        state.ordersPath.append(.detail(OrderDetail.State(orderID: id)))
        return .none

      case .cartPath(.element(_, .confirmation(.delegate(.continueShopping)))):
        state.cartPath.removeAll()
        state.shopPath.removeAll()
        state.selectedTab = .shop
        return .none

      case let .ordersList(.delegate(.openOrder(id))):
        state.ordersPath.append(.detail(OrderDetail.State(orderID: id)))
        return .none

      case let .ordersPath(.element(_, .detail(.delegate(.orderCancelled(order))))):
        return .send(.ordersList(.orderUpdated(order)))

      case .profile(.delegate(.loggedOut)):
        return .send(.delegate(.loggedOut))

      case .shop, .shopPath, .cart, .cartPath, .ordersList, .ordersPath, .profile, .delegate:
        return .none
      }
    }
    .forEach(\.shopPath, action: \.shopPath)
    .forEach(\.cartPath, action: \.cartPath)
    .forEach(\.ordersPath, action: \.ordersPath)
  }
}

extension HomeTabs.ShopPath.State: Equatable, Sendable {}
extension HomeTabs.ShopPath.Action: Sendable {}
extension HomeTabs.CartPath.State: Equatable, Sendable {}
extension HomeTabs.CartPath.Action: Sendable {}
extension HomeTabs.OrdersPath.State: Equatable, Sendable {}
extension HomeTabs.OrdersPath.Action: Sendable {}
