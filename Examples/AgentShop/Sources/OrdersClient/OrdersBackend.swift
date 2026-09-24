import Foundation
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

  /// The card the mock always declines.
  public static let declinedCard = "4000000000000002"

  /// Places an order: the next id after the user's newest (1001 for a first order), pending, dated `date`.
  /// Shipping and a promo discount are line items, so the order's total is what checkout showed.
  public func placeOrder(_ request: OrderRequest, for email: String, on date: Date) throws(OrdersError) -> Order {
    if request.cardNumber?.filter({ $0 != " " }) == Self.declinedCard { throw .paymentDeclined }
    var items = request.lines.map { line in
      OrderItem(
        name: line.size.map { "\(line.product.name) (\($0))" } ?? line.product.name,
        quantity: line.quantity,
        unitPriceCents: line.product.priceCents
      )
    }
    if request.shippingCents > 0 {
      items.append(OrderItem(name: "Express shipping", quantity: 1, unitPriceCents: request.shippingCents))
    }
    if request.discountCents > 0 {
      items.append(OrderItem(name: "Promo discount", quantity: 1, unitPriceCents: -request.discountCents))
    }
    let orders = ordersByEmail[email, default: []]
    let order = Order(id: (orders.map(\.id).max() ?? 1000) + 1, status: .pending, placedOn: date, items: items)
    ordersByEmail[email] = orders + [order]
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
