import AgentCtlCore
import ComposableArchitecture
import Models

extension Checkout: AgentScreen {
  public static let screenPaths = ["home/cart/checkout"]

  public static func screenPath(_ state: State) -> String { "home/cart/checkout" }

  public static let summaryKeys = [
    "name", "street", "city", "zip", "shipping", "payment", "total", "canPlace", "loading",
  ]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("name", state.address.name),
      SummaryItem("street", state.address.street),
      SummaryItem("city", state.address.city),
      SummaryItem("zip", state.address.zip),
      SummaryItem("shipping", state.shipping.rawValue),
      SummaryItem("payment", state.payment.rawValue),
      SummaryItem("total", formatCents(state.totalCents)),
      SummaryItem("canPlace", state.canPlace),
      SummaryItem("loading", state.isPlacing),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  /// Sent when checkout appears: it loads the saved address (`account.fetchProfile`).
  public static let onAppear: Action? = .onAppear

  static let shippings = Shipping.allCases.map(\.rawValue).joined(separator: "|")
  static let payments = Payment.allCases.map(\.rawValue).joined(separator: "|")

  public static let commands: [AgentCommand<State, Action>] = [
    .text("name", help: "Set the full name.") { .binding(.set(\.address.name, $0)) },
    .text("street", help: "Set the street.") { .binding(.set(\.address.street, $0)) },
    .text("city", help: "Set the city.") { .binding(.set(\.address.city, $0)) },
    .text("zip", help: "Set the zip code (five digits).") { .binding(.set(\.address.zip, $0)) },
    .parsing(
      "shipping",
      argument: "<\(shippings)>",
      help: "Standard is free; express adds \(formatCents(Checkout.expressShippingCents))."
    ) { text throws(AgentCommandError) in
      guard let shipping = Shipping(rawValue: text) else { throw .invalidArgument("expected \(shippings)") }
      return .shippingTapped(shipping)
    },
    .parsing("payment", argument: "<\(payments)>", help: "Pay by card or with Apple Pay.") {
      text throws(AgentCommandError) in
      guard let payment = Payment(rawValue: text) else { throw .invalidArgument("expected \(payments)") }
      return .paymentTapped(payment)
    },
    .text(
      "card",
      argument: "<number>",
      help: "Type the card number (16 digits; 4000 0000 0000 0002 is declined).",
      gate: CommandGate(hint: "payment=apple-pay") { $0.payment == .card }
    ) { .binding(.set(\.cardNumber, $0)) },
    .action(
      "place-order",
      help: "Place the order (orders.placeOrder). Reports invalidZip, invalidCard, paymentDeclined or network.",
      gate: CommandGate(hint: "canPlace=false") { $0.canPlace },
      .placeOrderTapped
    ),
  ]
}
