import AgentCtlCore
import ComposableArchitecture

extension OrdersList: AgentScreen {
  public static let screenPaths = ["home/orders"]

  public static func screenPath(_ state: State) -> String { "home/orders" }

  public static let summaryKeys = ["orders", "loading", "statuses"]

  public static func summary(_ state: State) -> [SummaryItem] {
    let statuses = state.orders.map(\.status.rawValue)
    return [
      SummaryItem("orders", state.orders.count),
      SummaryItem("loading", state.isLoading),
      SummaryItem("statuses", statuses.isEmpty ? "none" : statuses.joined(separator: ",")),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let onAppear: Action? = .onAppear

  public static let commands: [AgentCommand<State, Action>] = [
    .parsing("open", argument: "<id>", help: "Open an order, e.g. open 1003.") { text throws(AgentCommandError) in
      guard let id = Int(text) else { throw .invalidArgument("expected an order id such as 1003") }
      return .orderTapped(id)
    },
    .action("refresh", help: "Pull to refresh.", .refresh),
    .action(
      "retry",
      help: "Retry after a failed load.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retry
    ),
  ]
}
