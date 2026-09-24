import ComposableArchitecture
import Models
import OrdersClient

/// The signed-in user's orders. Loads on first appearance; supports pull to refresh and retry.
@Reducer
public struct OrdersList {
  public enum Phase: String, Equatable, Sendable {
    case loading
    case loaded
    case empty
    case failed
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var orders: IdentifiedArrayOf<Order>
    public var isLoading: Bool
    public var hasLoaded: Bool
    public var error: OrdersError?

    public init(
      orders: IdentifiedArrayOf<Order> = [],
      isLoading: Bool = false,
      hasLoaded: Bool = false,
      error: OrdersError? = nil
    ) {
      self.orders = orders
      self.isLoading = isLoading
      self.hasLoaded = hasLoaded
      self.error = error
    }

    /// What the screen shows. A failed refresh keeps the rows (`loaded`) and shows the error inline.
    public var phase: Phase {
      if !orders.isEmpty { return .loaded }
      if error != nil { return .failed }
      if hasLoaded && !isLoading { return .empty }
      return .loading
    }
  }

  public enum Action: Sendable {
    case onAppear
    case refresh
    case retry
    case ordersResponse(Result<[Order], OrdersError>)
    case orderTapped(Int)
    /// Sent by the container when another screen changed an order (e.g. it was cancelled).
    case orderUpdated(Order)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case openOrder(Int)
    }
  }

  enum CancelID { case load }

  @Dependency(\.ordersClient) var ordersClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard !state.hasLoaded, !state.isLoading else { return .none }
        return load(&state)

      case .refresh, .retry:
        return load(&state)

      case let .ordersResponse(.success(orders)):
        state.isLoading = false
        state.hasLoaded = true
        state.error = nil
        state.orders = IdentifiedArray(uniqueElements: orders)
        return .none

      case let .ordersResponse(.failure(error)):
        state.isLoading = false
        state.hasLoaded = true
        state.error = error
        return .none

      case let .orderTapped(id):
        return .send(.delegate(.openOrder(id)))

      case let .orderUpdated(order):
        state.orders[id: order.id] = order
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func load(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.error = nil
    return .run { [ordersClient] send in
      do {
        await send(.ordersResponse(.success(try await ordersClient.fetchOrders())))
      } catch {
        await send(.ordersResponse(.failure(OrdersError(error))))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}
