import ComposableArchitecture
import Models

/// One product: pick a size (when it has sizes) and a quantity (1–5), then add it to the cart. An out-of-stock
/// product can't be added. The cart itself lives in the tabs; this screen asks for the add through a delegate.
@Reducer
public struct ProductDetail {
  public static let maxQuantity = 5

  public enum Error: String, Equatable, Sendable {
    case maxQuantity
    case minQuantity
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var product: Product
    public var size: String?
    public var quantity: Int
    public var isFavorite: Bool
    /// How many this screen has put in the cart so far.
    public var added: Int
    public var error: Error?

    public init(
      product: Product,
      size: String? = nil,
      quantity: Int = 1,
      isFavorite: Bool = false,
      added: Int = 0,
      error: Error? = nil
    ) {
      self.product = product
      self.size = size
      self.quantity = quantity
      self.isFavorite = isFavorite
      self.added = added
      self.error = error
    }

    public var canAdd: Bool { product.inStock && (product.sizes.isEmpty || size != nil) }
  }

  public enum Action: Sendable {
    case sizeTapped(String)
    case quantityUpTapped
    case quantityDownTapped
    case favoriteToggled(Bool)
    case addToCartTapped
    case viewCartTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case add(CartLine)
      case viewCart
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .sizeTapped(size):
        guard state.product.sizes.contains(size) else { return .none }
        state.size = size
        return .none

      case .quantityUpTapped:
        guard state.quantity < Self.maxQuantity else {
          state.error = .maxQuantity
          return .none
        }
        state.quantity += 1
        state.error = nil
        return .none

      case .quantityDownTapped:
        guard state.quantity > 1 else {
          state.error = .minQuantity
          return .none
        }
        state.quantity -= 1
        state.error = nil
        return .none

      case let .favoriteToggled(isOn):
        state.isFavorite = isOn
        return .none

      case .addToCartTapped:
        guard state.canAdd else { return .none }
        state.added += state.quantity
        state.error = nil
        let line = CartLine(product: state.product, size: state.size, quantity: state.quantity)
        return .send(.delegate(.add(line)))

      case .viewCartTapped:
        return .send(.delegate(.viewCart))

      case .delegate:
        return .none
      }
    }
  }
}
