import ComposableArchitecture
import Models
import OrdersClient

/// One order: items, total, status and date. Pending orders can be cancelled.
@Reducer
public struct OrderDetail {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var orderID: Int
    public var order: Order?
    public var isLoading: Bool
    public var isCancelling: Bool
    public var error: OrdersError?

    public init(
      orderID: Int,
      order: Order? = nil,
      isLoading: Bool = false,
      isCancelling: Bool = false,
      error: OrdersError? = nil
    ) {
      self.orderID = orderID
      self.order = order
      self.isLoading = isLoading
      self.isCancelling = isCancelling
      self.error = error
    }

    /// Only pending orders can be cancelled, and not while a request is running.
    public var canCancel: Bool { order?.isCancellable == true && !isLoading && !isCancelling }
  }

  public enum Action: Sendable {
    case onAppear
    case retry
    case orderResponse(Result<Order, OrdersError>)
    case cancelTapped
    case cancelResponse(Result<Order, OrdersError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case orderCancelled(Order)
    }
  }

  @Dependency(\.ordersClient) var ordersClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard state.order == nil, !state.isLoading else { return .none }
        return load(&state)

      case .retry:
        return load(&state)

      case let .orderResponse(.success(order)):
        state.isLoading = false
        state.order = order
        return .none

      case let .orderResponse(.failure(error)):
        state.isLoading = false
        state.error = error
        return .none

      case .cancelTapped:
        guard state.canCancel else { return .none }
        state.isCancelling = true
        state.error = nil
        return .run { [ordersClient, id = state.orderID] send in
          do {
            await send(.cancelResponse(.success(try await ordersClient.cancelOrder(id))))
          } catch {
            await send(.cancelResponse(.failure(OrdersError(error))))
          }
        }

      case let .cancelResponse(.success(order)):
        state.isCancelling = false
        state.order = order
        return .send(.delegate(.orderCancelled(order)))

      case let .cancelResponse(.failure(error)):
        state.isCancelling = false
        state.error = error
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func load(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.error = nil
    return .run { [ordersClient, id = state.orderID] send in
      do {
        await send(.orderResponse(.success(try await ordersClient.fetchOrder(id))))
      } catch {
        await send(.orderResponse(.failure(OrdersError(error))))
      }
    }
  }
}
