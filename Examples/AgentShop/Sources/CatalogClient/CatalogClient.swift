import AgentCtlCore
import ComposableArchitecture
import Models

/// Errors from the catalog server. The raw value is the code agents see as `error=<code>`.
public enum CatalogError: String, Error, Codable, CaseIterable, Hashable, Sendable {
  case network
  case timeout

  public init(_ error: any Error) {
    self = error as? CatalogError ?? .network
  }
}

/// The product catalog. Everything is mocked: `liveValue` returns ``Catalog/products``.
@DependencyClient
public struct CatalogClient: Sendable {
  public var fetchProducts: @Sendable () async throws -> [Product]
}

extension CatalogClient: DependencyKey {
  public static let liveValue = CatalogClient(
    fetchProducts: {
      try await shopCall("catalog.fetchProducts", error: { CatalogError(rawValue: $0) ?? .network }) { Catalog.products }
    }
  )

  public static let testValue = CatalogClient()
  public static let previewValue = liveValue

  public static let mockMethods: [MockMethod] = [
    MockMethod("catalog.fetchProducts", errorCodes: CatalogError.allCases.map(\.rawValue))
  ]
}

extension DependencyValues {
  public var catalogClient: CatalogClient {
    get { self[CatalogClient.self] }
    set { self[CatalogClient.self] = newValue }
  }
}

/// Twelve products, two per category, in "featured" order. SKUs are 101–112 so agents can type them.
public enum Catalog {
  public static let shoeSizes = ["40", "41", "42", "43", "44"]
  public static let jacketSizes = ["S", "M", "L"]

  public static let products: [Product] = [
    Product(id: 101, name: "Trail Runner", category: .shoes, priceCents: 8900, sizes: shoeSizes),
    Product(id: 102, name: "City Sneaker", category: .shoes, priceCents: 6400, sizes: shoeSizes),
    Product(id: 103, name: "Canvas Tote", category: .bags, priceCents: 2900),
    Product(id: 104, name: "Leather Backpack", category: .bags, priceCents: 12900),
    Product(id: 105, name: "Field Watch", category: .watches, priceCents: 14900),
    Product(id: 106, name: "Dive Watch", category: .watches, priceCents: 24900),
    Product(id: 107, name: "Rain Jacket", category: .jackets, priceCents: 11900, sizes: jacketSizes),
    Product(id: 108, name: "Down Jacket", category: .jackets, priceCents: 18900, sizes: jacketSizes),
    Product(id: 109, name: "Wool Beanie", category: .accessories, priceCents: 1900, inStock: false),
    Product(id: 110, name: "Sunglasses", category: .accessories, priceCents: 5900),
    Product(id: 111, name: "Ceramic Mug", category: .home, priceCents: 1400),
    Product(id: 112, name: "Linen Throw", category: .home, priceCents: 4900),
  ]
}
