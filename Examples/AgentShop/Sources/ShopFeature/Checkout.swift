import AccountClient
import ComposableArchitecture
import Models
import OrdersClient

/// Checkout: the shipping address (prefilled from the account), shipping speed and payment, then "Place order".
/// Local checks come first — a zip that isn't five digits is `invalidZip`, a card that isn't 16 digits
/// `invalidCard` — then the server may decline the card (`paymentDeclined`) or fail (`network`); placing again
/// retries.
@Reducer
public struct Checkout {
  public static let expressShippingCents = 1500

  public enum Shipping: String, CaseIterable, Equatable, Sendable {
    case standard
    case express
  }

  public enum Payment: String, CaseIterable, Equatable, Sendable {
    case card
    case applePay = "apple-pay"
  }

  /// The raw values are what agents see as `error=<code>`: the form's own checks, then the server's.
  public enum Error: String, Equatable, Sendable {
    case invalidZip
    case invalidCard
    case paymentDeclined
    case network
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var lines: [CartLine]
    public var discountCents: Int
    public var address: Address
    public var shipping: Shipping
    public var payment: Payment
    public var cardNumber: String
    public var isPlacing: Bool
    public var hasLoadedAddress: Bool
    public var error: Error?

    public init(
      lines: [CartLine],
      discountCents: Int = 0,
      address: Address = Address(),
      shipping: Shipping = .standard,
      payment: Payment = .card,
      cardNumber: String = "",
      isPlacing: Bool = false,
      hasLoadedAddress: Bool = false,
      error: Error? = nil
    ) {
      self.lines = lines
      self.discountCents = discountCents
      self.address = address
      self.shipping = shipping
      self.payment = payment
      self.cardNumber = cardNumber
      self.isPlacing = isPlacing
      self.hasLoadedAddress = hasLoadedAddress
      self.error = error
    }

    public var subtotalCents: Int { lines.reduce(0) { $0 + $1.totalCents } }
    public var shippingCents: Int { shipping == .express ? Checkout.expressShippingCents : 0 }
    public var totalCents: Int { subtotalCents - discountCents + shippingCents }
    public var canPlace: Bool {
      address.isComplete && (payment == .applePay || !cardNumber.isEmpty) && !isPlacing
    }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case onAppear
    case profileLoaded(AccountProfile?)
    case shippingTapped(Shipping)
    case paymentTapped(Payment)
    case placeOrderTapped
    case placed(Result<Order, OrdersError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case placed(Order)
    }
  }

  @Dependency(\.accountClient) var accountClient
  @Dependency(\.ordersClient) var ordersClient

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.error = nil
        return .none

      case .onAppear:
        guard !state.hasLoadedAddress else { return .none }
        state.hasLoadedAddress = true
        return .run { [accountClient] send in
          await send(.profileLoaded(try? await accountClient.fetchProfile()))
        }

      case let .profileLoaded(profile):
        // Prefill only an untouched form: never overwrite what the shopper typed.
        if let address = profile?.address, state.address == Address() {
          state.address = address
        }
        return .none

      case let .shippingTapped(shipping):
        state.shipping = shipping
        return .none

      case let .paymentTapped(payment):
        state.payment = payment
        state.error = nil
        return .none

      case .placeOrderTapped:
        guard state.canPlace else { return .none }
        guard isValidZip(state.address.zip) else {
          state.error = .invalidZip
          return .none
        }
        if state.payment == .card, !isValidCardNumber(state.cardNumber) {
          state.error = .invalidCard
          return .none
        }
        state.isPlacing = true
        state.error = nil
        let request = OrderRequest(
          lines: state.lines,
          address: state.address,
          shippingCents: state.shippingCents,
          discountCents: state.discountCents,
          cardNumber: state.payment == .card ? state.cardNumber : nil
        )
        return .run { [ordersClient] send in
          do {
            await send(.placed(.success(try await ordersClient.placeOrder(request))))
          } catch {
            await send(.placed(.failure(OrdersError(error))))
          }
        }

      case let .placed(.success(order)):
        state.isPlacing = false
        return .send(.delegate(.placed(order)))

      case let .placed(.failure(error)):
        state.isPlacing = false
        state.error = error == .paymentDeclined ? .paymentDeclined : .network
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
