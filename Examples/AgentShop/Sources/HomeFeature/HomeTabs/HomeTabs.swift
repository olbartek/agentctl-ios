import ComposableArchitecture
import Foundation
import Models

/// The signed-in area: an orders tab (list → detail stack) and a profile tab.
@Reducer
public struct HomeTabs {
  public enum Tab: String, CaseIterable, Equatable, Sendable {
    case orders
    case profile
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
    public var ordersList: OrdersList.State
    public var ordersPath: StackState<OrdersPath.State>
    public var profile: Profile.State

    public init(
      id: UUID,
      session: Session,
      selectedTab: Tab = .orders,
      ordersList: OrdersList.State = OrdersList.State(),
      ordersPath: StackState<OrdersPath.State> = StackState()
    ) {
      self.id = id
      self.selectedTab = selectedTab
      self.ordersList = ordersList
      self.ordersPath = ordersPath
      self.profile = Profile.State(user: session.user)
    }
  }

  public enum Action: Sendable {
    case tabSelected(Tab)
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
    Scope(state: \.ordersList, action: \.ordersList) {
      OrdersList()
    }
    Scope(state: \.profile, action: \.profile) {
      Profile()
    }
    Reduce { state, action in
      switch action {
      case let .tabSelected(tab):
        state.selectedTab = tab
        return .none

      case let .ordersList(.delegate(.openOrder(id))):
        state.ordersPath.append(.detail(OrderDetail.State(orderID: id)))
        return .none

      case let .ordersPath(.element(_, .detail(.delegate(.orderCancelled(order))))):
        return .send(.ordersList(.orderUpdated(order)))

      case .profile(.delegate(.loggedOut)):
        return .send(.delegate(.loggedOut))

      case .ordersList, .ordersPath, .profile, .delegate:
        return .none
      }
    }
    .forEach(\.ordersPath, action: \.ordersPath)
  }
}

extension HomeTabs.OrdersPath.State: Equatable, Sendable {}
extension HomeTabs.OrdersPath.Action: Sendable {}
