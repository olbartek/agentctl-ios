import ComposableArchitecture
import Models

/// "Thanks for your order": the new order's number and total, then on to the order or back to the shop.
@Reducer
public struct OrderConfirmation {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var order: Order

    public init(order: Order) {
      self.order = order
    }
  }

  public enum Action: Sendable {
    case viewOrderTapped
    case continueShoppingTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case viewOrder(Int)
      case continueShopping
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .viewOrderTapped:
        return .send(.delegate(.viewOrder(state.order.id)))
      case .continueShoppingTapped:
        return .send(.delegate(.continueShopping))
      case .delegate:
        return .none
      }
    }
  }
}
