import AgentCtlCore
import ComposableArchitecture
import Models
import SessionClient

/// Orders of the signed-in user. Everything is mocked: `liveValue` talks to the in-memory ``OrdersBackend``
/// and identifies the user from ``SessionStorage``, the way a server reads a token.
@DependencyClient
public struct OrdersClient: Sendable {
  public var fetchOrders: @Sendable () async throws -> [Order]
  public var fetchOrder: @Sendable (_ id: Int) async throws -> Order
  public var cancelOrder: @Sendable (_ id: Int) async throws -> Order
  public var placeOrder: @Sendable (_ request: OrderRequest) async throws -> Order
}

extension OrdersClient: DependencyKey {
  public static let liveValue = OrdersClient(
    fetchOrders: {
      try await ordersCall("orders.fetchOrders") { backend, email in await backend.orders(for: email) }
    },
    fetchOrder: { id in
      try await ordersCall("orders.fetchOrder") { backend, email in try await backend.order(id: id, for: email) }
    },
    cancelOrder: { id in
      try await ordersCall("orders.cancelOrder") { backend, email in try await backend.cancelOrder(id: id, for: email) }
    },
    placeOrder: { request in
      @Dependency(\.date.now) var now
      return try await ordersCall("orders.placeOrder") { backend, email in
        try await backend.placeOrder(request, for: email, on: now)
      }
    }
  )

  public static let testValue = OrdersClient()
  public static let previewValue = liveValue

  /// The methods `mock orders.<method> <error>` accepts, with their error codes.
  public static let mockMethods: [MockMethod] = ["fetchOrders", "fetchOrder", "cancelOrder", "placeOrder"].map {
    MockMethod("orders.\($0)", errorCodes: OrdersError.allCases.map(\.rawValue))
  }
}

extension DependencyValues {
  public var ordersClient: OrdersClient {
    get { self[OrdersClient.self] }
    set { self[OrdersClient.self] = newValue }
  }
}

private func ordersCall<T: Sendable>(
  _ name: String,
  _ body: @Sendable (OrdersBackend, String) async throws -> T
) async throws -> T {
  try await shopCall(name, error: { OrdersError(rawValue: $0) ?? .network }) {
    @Dependency(\.sessionStorage) var sessionStorage
    @Dependency(\.ordersBackend) var backend
    guard let email = sessionStorage.currentSession?.user.email else { throw OrdersError.unauthorized }
    return try await body(backend, email)
  }
}
