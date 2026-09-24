import CatalogClient
import ComposableArchitecture
import Models

/// The shop's home: every product, filterable by category, searchable by name and sortable by price. It loads once,
/// when it first appears; a failed load shows the error with retry, and a failed refresh keeps the products.
@Reducer
public struct ShopFeed {
  public enum Sort: String, CaseIterable, Equatable, Sendable {
    case featured
    case priceAsc = "price-asc"
    case priceDesc = "price-desc"
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var products: [Product]
    /// `nil` is "all".
    public var filter: ProductCategory?
    public var query: String
    public var sort: Sort
    public var isLoading: Bool
    public var hasLoaded: Bool
    public var error: CatalogError?

    public init(
      products: [Product] = [],
      filter: ProductCategory? = nil,
      query: String = "",
      sort: Sort = .featured,
      isLoading: Bool = false,
      hasLoaded: Bool = false,
      error: CatalogError? = nil
    ) {
      self.products = products
      self.filter = filter
      self.query = query
      self.sort = sort
      self.isLoading = isLoading
      self.hasLoaded = hasLoaded
      self.error = error
    }

    /// What the list shows: filtered by category and name, then sorted.
    public var visible: [Product] {
      let query = query.trimmingCharacters(in: .whitespaces).lowercased()
      let matching = products.filter { product in
        (filter == nil || product.category == filter)
          && (query.isEmpty || product.name.lowercased().contains(query))
      }
      switch sort {
      case .featured: return matching
      case .priceAsc: return matching.sorted { ($0.priceCents, $0.id) < ($1.priceCents, $1.id) }
      case .priceDesc: return matching.sorted { ($0.priceCents, -$0.id) > ($1.priceCents, -$1.id) }
      }
    }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case onAppear
    case refresh
    case retry
    case productsResponse(Result<[Product], CatalogError>)
    case filterTapped(ProductCategory?)
    case sortTapped(Sort)
    case clearSearchTapped
    case productTapped(Int)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case openProduct(Product)
    }
  }

  enum CancelID { case load }

  @Dependency(\.catalogClient) var catalogClient

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        guard !state.hasLoaded, !state.isLoading else { return .none }
        return load(&state)

      case .refresh, .retry:
        return load(&state)

      case let .productsResponse(.success(products)):
        state.isLoading = false
        state.hasLoaded = true
        state.products = products
        return .none

      case let .productsResponse(.failure(error)):
        state.isLoading = false
        state.hasLoaded = true
        state.error = error
        return .none

      case let .filterTapped(filter):
        state.filter = filter
        return .none

      case let .sortTapped(sort):
        state.sort = sort
        return .none

      case .clearSearchTapped:
        state.query = ""
        return .none

      case let .productTapped(id):
        guard let product = state.products.first(where: { $0.id == id }) else { return .none }
        return .send(.delegate(.openProduct(product)))

      case .delegate:
        return .none
      }
    }
  }

  private func load(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.error = nil
    return .run { [catalogClient] send in
      do {
        await send(.productsResponse(.success(try await catalogClient.fetchProducts())))
      } catch {
        await send(.productsResponse(.failure(CatalogError(error))))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}
