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

  public static let commands: [AgentCommand<State, Action>] = [
    .choice(
      "toggle",
      of: ProductCategory.self,
      help: "Pick or unpick a category (\(Interests.minimum)–\(Interests.maximum)); a fifth reports error=tooMany."
    ) { .toggled($0) },
    .action(
      "continue",
      help: "Save the picks and go on to the address.",
      gate: CommandGate(hint: "canContinue=false") { $0.canContinue },
      .continueTapped
    ),
  ]
}
