import AgentCtlCore
import ComposableArchitecture
import Models

extension ProductDetail: AgentScreen {
  public static let screenPaths = ["home/shop/<sku>"]

  public static func screenPath(_ state: State) -> String { "home/shop/\(state.product.id)" }

  public static let summaryKeys = ["name", "price", "size", "qty", "inStock", "favorite", "canAdd", "added"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("name", state.product.name),
      SummaryItem("price", formatCents(state.product.priceCents)),
      SummaryItem("size", state.product.sizes.isEmpty ? "one-size" : state.size ?? "none"),
      SummaryItem("qty", state.quantity),
      SummaryItem("inStock", state.product.inStock),
      SummaryItem("favorite", state.isFavorite),
      SummaryItem("canAdd", state.canAdd),
      SummaryItem("added", state.added),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("size", argument: "<size>", help: "Pick a size, e.g. size 42 or size M.") { .sizeTapped($0) },
    .action(
      "qty-up",
      help: "One more (at most \(ProductDetail.maxQuantity); beyond that error=maxQuantity).",
      .quantityUpTapped
    ),
    .action("qty-down", help: "One fewer (at least 1; below that error=minQuantity).", .quantityDownTapped),
    .onOff("favorite", help: "Mark or unmark as a favorite.") { .favoriteToggled($0) },
    .action(
      "add-to-cart",
      help: "Add the quantity in the chosen size to the cart. Needs a size when the product has sizes.",
      gate: CommandGate(hint: "canAdd=false") { $0.canAdd },
      .addToCartTapped
    ),
    .action("view-cart", help: "Switch to the cart tab.", .viewCartTapped),
  ]
}
