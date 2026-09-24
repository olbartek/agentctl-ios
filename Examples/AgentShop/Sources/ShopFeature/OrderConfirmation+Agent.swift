import AgentCtlCore
import ComposableArchitecture
import Models

extension OrderConfirmation: AgentScreen {
  public static let screenPaths = ["home/cart/confirmation"]

  public static func screenPath(_ state: State) -> String { "home/cart/confirmation" }

  public static let summaryKeys = ["order", "total"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [SummaryItem("order", state.order.id), SummaryItem("total", formatCents(state.order.totalCents))]
  }

  public static let commands: [AgentCommand<State, Action>] = [
    .action("view-order", help: "Open the new order in the orders tab.", .viewOrderTapped),
    .action("continue-shopping", help: "Back to the shop, with an empty cart.", .continueShoppingTapped),
  ]
}
