import AgentCtlCore
import ComposableArchitecture

/// The detail screen's agent surface. Its path carries the item's id, which is how `expect screen=items/2`
/// tells one pushed screen from another.
extension ItemDetail: AgentScreen {
  /// `<id>` stands for the variable part: this is the path as the docs list it, once.
  public static let screenPaths = ["items/<id>"]

  public static func screenPath(_ state: State) -> String { "items/\(state.item.id)" }

  public static let summaryKeys = ["title", "saved", "cooldown"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("title", state.item.title),
      SummaryItem("saved", state.saved),
      SummaryItem("cooldown", state.cooldown),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .action(
      "save",
      help: "Save this item. A save starts a \(ItemDetail.cooldownSeconds)-second cooldown; saving again "
        + "before it runs out reports error=cooldown.",
      .saveTapped
    )
  ]
}
