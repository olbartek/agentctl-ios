import AgentCtlCore
import ComposableArchitecture
import Models

extension ShopFeed: AgentScreen {
  public static let screenPaths = ["home/shop"]

  public static func screenPath(_ state: State) -> String { "home/shop" }

  public static let summaryKeys = ["products", "filter", "query", "sort", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("products", state.visible.count),
      SummaryItem("filter", state.filter?.rawValue ?? "all"),
      SummaryItem("query", state.query),
      SummaryItem("sort", state.sort.rawValue),
      SummaryItem("loading", state.isLoading),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  /// Headlessly there is no view to send this, so the runtime sends it when the screen becomes active.
  public static let onAppear: Action? = .onAppear

  static let filters = (["all"] + ProductCategory.allCases.map(\.rawValue)).joined(separator: "|")
  static let sorts = Sort.allCases.map(\.rawValue).joined(separator: "|")

  public static let commands: [AgentCommand<State, Action>] = [
    .parsing("filter", argument: "<\(filters)>", help: "Show one category, or all.") { text throws(AgentCommandError) in
      if text == "all" { return .filterTapped(nil) }
      guard let category = ProductCategory(rawValue: text) else { throw .invalidArgument("expected \(filters)") }
      return .filterTapped(category)
    },
    .text("search", help: "Type in the search field; matches product names as you type.") {
      .binding(.set(\.query, $0))
    },
    .action("clear-search", help: "Clear the search field.", .clearSearchTapped),
    .parsing("sort", argument: "<\(sorts)>", help: "Sort the products.") { text throws(AgentCommandError) in
      guard let sort = Sort(rawValue: text) else { throw .invalidArgument("expected \(sorts)") }
      return .sortTapped(sort)
    },
    .parsing(
      "open",
      argument: "<sku>",
      help: "Open a product, e.g. open 101.",
      gate: CommandGate(hint: "products=0") { !$0.visible.isEmpty }
    ) { text throws(AgentCommandError) in
      guard let id = Int(text) else { throw .invalidArgument("expected a SKU such as 101") }
      return .productTapped(id)
    },
    .action("refresh", help: "Load the catalog again.", .refresh),
    .action(
      "retry",
      help: "Load the catalog again after a failure.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retry
    ),
  ]
}
