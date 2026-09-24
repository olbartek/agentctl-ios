import AgentCtlCore
import ComposableArchitecture
import Models

extension Interests: AgentScreen {
  public static let screenPaths = ["onboarding/interests"]

  public static func screenPath(_ state: State) -> String { "onboarding/interests" }

  public static let summaryKeys = ["selected", "interests", "canContinue"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("selected", state.selected.count),
      SummaryItem("interests", state.selected.isEmpty ? "none" : state.selected.map(\.rawValue).joined(separator: ",")),
      SummaryItem("canContinue", state.canContinue),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  static let categories = ProductCategory.allCases.map(\.rawValue).joined(separator: "|")

  public static let commands: [AgentCommand<State, Action>] = [
    .parsing(
      "toggle",
      argument: "<\(categories)>",
      help: "Pick or unpick a category (\(Interests.minimum)–\(Interests.maximum)); a fifth reports error=tooMany."
    ) { text throws(AgentCommandError) in
      guard let category = ProductCategory(rawValue: text) else { throw .invalidArgument("expected \(categories)") }
      return .toggled(category)
    },
    .action(
      "continue",
      help: "Save the picks and go on to the address.",
      gate: CommandGate(hint: "canContinue=false") { $0.canContinue },
      .continueTapped
    ),
  ]
}
