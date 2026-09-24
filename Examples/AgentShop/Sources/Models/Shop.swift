/// What the shop sells, and what a shopper picks as interests during onboarding.
public enum ProductCategory: String, CaseIterable, Codable, Hashable, Sendable {
  case shoes
  case bags
  case watches
  case jackets
  case accessories
  case home
}

/// One product in the catalog. `id` is the SKU agents type: `open 101`.
public struct Product: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: Int
  public var name: String
  public var category: ProductCategory
  public var priceCents: Int
  /// Empty when the product comes in one size.
  public var sizes: [String]
  public var inStock: Bool

  public init(id: Int, name: String, category: ProductCategory, priceCents: Int, sizes: [String] = [], inStock: Bool = true) {
    self.id = id
    self.name = name
    self.category = category
    self.priceCents = priceCents
    self.sizes = sizes
    self.inStock = inStock
  }
}

/// A product in the cart, in one size. Its id is what `inc`, `dec` and `remove` take: `101-42`, or `103` for a
/// product without sizes.
public struct CartLine: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var product: Product
  public var size: String?
  public var quantity: Int

  public init(product: Product, size: String?, quantity: Int) {
    self.product = product
    self.size = size
    self.quantity = quantity
  }

  public var id: String { size.map { "\(product.id)-\($0)" } ?? "\(product.id)" }
  public var totalCents: Int { product.priceCents * quantity }
}

/// A shipping address.
public struct Address: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var street: String
  public var city: String
  public var zip: String

  public init(name: String = "", street: String = "", city: String = "", zip: String = "") {
    self.name = name
    self.street = street
    self.city = city
    self.zip = zip
  }

  /// Every field filled in (a zip may still be malformed; see ``isValidZip(_:)``).
  public var isComplete: Bool {
    [name, street, city, zip].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }
}

/// A US-style zip code: exactly five digits.
public func isValidZip(_ zip: String) -> Bool {
  zip.count == 5 && zip.allSatisfy(\.isASCII) && zip.allSatisfy(\.isNumber)
}

/// A payment card number the mock accepts: 16 digits, spaces allowed.
public func isValidCardNumber(_ number: String) -> Bool {
  let digits = number.filter { $0 != " " }
  return digits.count == 16 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
}

/// What the account server knows about a shopper beyond their session.
public struct AccountProfile: Codable, Equatable, Sendable {
  /// A new account (registered, or first seen through Google) goes through onboarding once.
  public var needsOnboarding: Bool
  public var interests: [ProductCategory]
  /// The address saved during onboarding, which prefills checkout.
  public var address: Address?

  public init(needsOnboarding: Bool, interests: [ProductCategory] = [], address: Address? = nil) {
    self.needsOnboarding = needsOnboarding
    self.interests = interests
    self.address = address
  }
}

/// What a shopper chose during onboarding.
public struct OnboardingAnswers: Codable, Equatable, Sendable {
  public var interests: [ProductCategory]
  public var address: Address?
  public var notifications: Bool

  public init(interests: [ProductCategory], address: Address?, notifications: Bool) {
    self.interests = interests
    self.address = address
    self.notifications = notifications
  }
}

/// Errors from the account server. The raw value is the code agents see as `error=<code>`.
public enum AccountError: String, Error, Codable, CaseIterable, Hashable, Sendable {
  case network
  case unauthorized

  public init(_ error: any Error) {
    self = error as? AccountError ?? .network
  }
}
