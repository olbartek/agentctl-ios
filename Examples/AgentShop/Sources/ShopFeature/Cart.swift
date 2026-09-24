import CartClient
import ComposableArchitecture
import Models

/// The cart: lines grouped by product and size, quantities, and one promo code. The server checks the code.
@Reducer
public struct Cart {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var lines: IdentifiedArrayOf<CartLine>
    /// What is typed in the promo field.
    public var promoCode: String
    public var promo: Promo?
    public var isApplyingPromo: Bool
    public var error: CartError?

    public init(
      lines: IdentifiedArrayOf<CartLine> = [],
      promoCode: String = "",
      promo: Promo? = nil,
      isApplyingPromo: Bool = false,
      error: CartError? = nil
    ) {
      self.lines = lines
      self.promoCode = promoCode
      self.promo = promo
      self.isApplyingPromo = isApplyingPromo
      self.error = error
    }

    public var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }
    public var subtotalCents: Int { lines.reduce(0) { $0 + $1.totalCents } }
    public var discountCents: Int { promo?.discount(on: subtotalCents) ?? 0 }
    public var totalCents: Int { subtotalCents - discountCents }
    public var canCheckout: Bool { !lines.isEmpty }
    public var canApplyPromo: Bool {
      !promoCode.trimmingCharacters(in: .whitespaces).isEmpty && !isApplyingPromo
    }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    /// From the product screen, through the tabs.
    case add(CartLine)
    case incrementTapped(CartLine.ID)
    case decrementTapped(CartLine.ID)
    case removeTapped(CartLine.ID)
    case applyPromoTapped
    case promoResponse(Result<Promo, CartError>)
    case clearPromoTapped
    case checkoutTapped
    /// Sent by the tabs once an order is placed.
    case emptied
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case checkout
    }
  }

  @Dependency(\.cartClient) var cartClient

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.promoCode):
        state.error = nil
        return .none

      case .binding:
        return .none

      case let .add(line):
        if var existing = state.lines[id: line.id] {
          existing.quantity += line.quantity
          state.lines[id: line.id] = existing
        } else {
          state.lines.append(line)
        }
        return .none

      case let .incrementTapped(id):
        state.lines[id: id]?.quantity += 1
        return .none

      case let .decrementTapped(id):
        guard let line = state.lines[id: id] else { return .none }
        if line.quantity > 1 {
          state.lines[id: id]?.quantity -= 1
        } else {
          state.lines.remove(id: id)
        }
        return .none

      case let .removeTapped(id):
        state.lines.remove(id: id)
        return .none

      case .applyPromoTapped:
        guard state.canApplyPromo else { return .none }
        state.isApplyingPromo = true
        state.error = nil
        return .run { [cartClient, code = state.promoCode] send in
          do {
            await send(.promoResponse(.success(try await cartClient.applyPromo(code))))
          } catch {
            await send(.promoResponse(.failure(CartError(error))))
          }
        }

      case let .promoResponse(.success(promo)):
        state.isApplyingPromo = false
        state.promo = promo
        state.promoCode = ""
        return .none

      case let .promoResponse(.failure(error)):
        state.isApplyingPromo = false
        state.error = error
        return .none

      case .clearPromoTapped:
        state.promo = nil
        return .none

      case .checkoutTapped:
        guard state.canCheckout else { return .none }
        return .send(.delegate(.checkout))

      case .emptied:
        state = State()
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
