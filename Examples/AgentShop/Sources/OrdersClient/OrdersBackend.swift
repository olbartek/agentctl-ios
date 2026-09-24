import ComposableArchitecture
import Models

/// The in-memory orders server behind ``OrdersClient``'s `liveValue`. Orders are keyed by the owner's email.
public actor OrdersBackend {
  private var ordersByEmail: [String: [Order]]

  public init(seed: [String: [Order]] = MockOrders.seed) {
    self.ordersByEmail = seed
  }

  /// The user's orders, newest id last.
  public func orders(for email: String) -> [Order] {
    ordersByEmail[email, default: []].sorted { $0.id < $1.id }
  }

  public func order(id: Int, for email: String) throws(OrdersError) -> Order {
    guard let order = ordersByEmail[email, default: []].first(where: { $0.id == id }) else { throw .notFound }
    return order
  }

  /// Cancels a pending order; any other status gives `notCancellable`.
  public func cancelOrder(id: Int, for email: String) throws(OrdersError) -> Order {
    guard var orders = ordersByEmail[email], let index = orders.firstIndex(where: { $0.id == id }) else {
      throw .notFound
    }
    guard orders[index].isCancellable else { throw .notCancellable }
    orders[index].status = .cancelled
    ordersByEmail[email] = orders
    return orders[index]
  }
}

/// Seeded orders: Alice has three (delivered, shipped, pending); Bob has none.
public enum MockOrders {
  public static let alice: [Order] = [
    Order(
      id: 1001,
      status: .delivered,
      placedOn: day("2025-12-10"),
      items: [
        OrderItem(name: "Wireless Mouse", quantity: 1, unitPriceCents: 2499),
        OrderItem(name: "USB-C Cable", quantity: 2, unitPriceCents: 950),
      ]
    ),
    Order(
      id: 1002,
      status: .shipped,
      placedOn: day("2025-12-22"),
      items: [OrderItem(name: "Mechanical Keyboard", quantity: 1, unitPriceCents: 8900)]
    ),
    Order(
      id: 1003,
      status: .pending,
      placedOn: day("2025-12-30"),
      items: [
        OrderItem(name: "Laptop Stand", quantity: 1, unitPriceCents: 3990),
        OrderItem(name: "Desk Mat", quantity: 1, unitPriceCents: 1990),
      ]
    ),
  ]

  public static let seed: [String: [Order]] = ["alice@example.com": alice]
}

public enum OrdersBackendKey: DependencyKey {
  public static let liveValue = OrdersBackend()
  public static var testValue: OrdersBackend {
    reportIssue("OrdersBackend is not overridden. Construct one explicitly in the test.")
    return OrdersBackend()
  }
  public static var previewValue: OrdersBackend { OrdersBackend() }
}

extension DependencyValues {
  public var ordersBackend: OrdersBackend {
    get { self[OrdersBackendKey.self] }
    set { self[OrdersBackendKey.self] = newValue }
  }
}
