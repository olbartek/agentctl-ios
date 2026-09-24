import AgentCtlCore
import ComposableArchitecture
import Models

extension Cart: AgentScreen {
  public static let screenPaths = ["home/cart"]

  public static func screenPath(_ state: State) -> String { "home/cart" }

  public static let summaryKeys = ["lines", "items", "subtotal", "discount", "total", "promo", "canCheckout"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("lines", state.lines.isEmpty ? "none" : state.lines.map(\.id).joined(separator: ",")),
      SummaryItem("items", state.itemCount),
      SummaryItem("subtotal", formatCents(state.subtotalCents)),
      SummaryItem("discount", formatCents(state.discountCents)),
      SummaryItem("total", formatCents(state.totalCents)),
      SummaryItem("promo", state.promo?.code ?? "none"),
      SummaryItem("canCheckout", state.canCheckout),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .parsing("inc", argument: "<line>", help: "One more of a line, e.g. inc 101-42 or inc 103.") {
      text throws(AgentCommandError) in .incrementTapped(text)
    },
    .parsing("dec", argument: "<line>", help: "One fewer of a line; at one, the line is removed.") {
      text throws(AgentCommandError) in .decrementTapped(text)
    },
    .parsing("remove", argument: "<line>", help: "Remove a line.") { text throws(AgentCommandError) in
      .removeTapped(text)
    },
    .text("promo", help: "Type a promo code (SAVE10 and HALF exist).") { .binding(.set(\.promoCode, $0)) },
    .action(
      "apply-promo",
      help: "Apply the typed code (cart.applyPromo); an unknown one reports error=invalidPromo.",
      gate: CommandGate(hint: "no code typed") { $0.canApplyPromo },
      .applyPromoTapped
    ),
    .action(
      "clear-promo",
      help: "Remove the applied promo code.",
      gate: CommandGate(hint: "promo=none") { $0.promo != nil },
      .clearPromoTapped
    ),
    .action(
      "checkout",
      help: "Go to checkout.",
      gate: CommandGate(hint: "canCheckout=false") { $0.canCheckout },
      .checkoutTapped
    ),
  ]
}
