import Foundation

public enum OrderStatus: String, Codable, CaseIterable, Hashable, Sendable {
  case pending
  case shipped
  case delivered
  case cancelled
}

public struct OrderItem: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var quantity: Int
  public var unitPriceCents: Int

  public init(name: String, quantity: Int, unitPriceCents: Int) {
    self.name = name
    self.quantity = quantity
    self.unitPriceCents = unitPriceCents
  }

  public var totalCents: Int { quantity * unitPriceCents }
}

public struct Order: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: Int
  public var status: OrderStatus
  public var placedOn: Date
  public var items: [OrderItem]

  public init(id: Int, status: OrderStatus, placedOn: Date, items: [OrderItem]) {
    self.id = id
    self.status = status
    self.placedOn = placedOn
    self.items = items
  }

  public var totalCents: Int { items.reduce(0) { $0 + $1.totalCents } }

  /// Only pending orders can be cancelled.
  public var isCancellable: Bool { status == .pending }
}

/// What checkout sends to place an order.
public struct OrderRequest: Codable, Equatable, Hashable, Sendable {
  public var lines: [CartLine]
  public var address: Address
  public var shippingCents: Int
  public var discountCents: Int
  /// `nil` for Apple Pay.
  public var cardNumber: String?

  public init(lines: [CartLine], address: Address, shippingCents: Int, discountCents: Int, cardNumber: String?) {
    self.lines = lines
    self.address = address
    self.shippingCents = shippingCents
    self.discountCents = discountCents
    self.cardNumber = cardNumber
  }
}
