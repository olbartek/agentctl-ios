import AgentCtlCore
import ComposableArchitecture
import Models

extension OrderDetail: AgentScreen {
  public static let screenPaths = ["home/orders/<id>"]

  public static func screenPath(_ state: State) -> String { "home/orders/\(state.orderID)" }

  public static let summaryKeys = ["id", "status", "items", "total", "date", "canCancel", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    var items = [SummaryItem("id", state.orderID)]
    if let order = state.order {
      items += [
        SummaryItem("status", order.status.rawValue),
        SummaryItem("items", order.items.count),
        SummaryItem("total", formatCents(order.totalCents)),
        SummaryItem("date", formatDay(order.placedOn)),
      ]
    }
    items += [
      SummaryItem("canCancel", state.canCancel),
      SummaryItem("loading", state.isLoading || state.isCancelling),
    ]
    return items
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let onAppear: Action? = .onAppear

  public static let commands: [AgentCommand<State, Action>] = [
    .action(
      "cancel",
      help: "Cancel the order (pending orders only).",
      gate: CommandGate(hint: "canCancel=false") { $0.canCancel },
      .cancelTapped
    ),
    .action(
      "retry",
      help: "Reload the order after an error.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retry
    ),
  ]
}
