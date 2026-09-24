import AgentCtlCore
import ComposableArchitecture

extension Notifications: AgentScreen {
  public static let screenPaths = ["onboarding/notifications"]

  public static func screenPath(_ state: State) -> String { "onboarding/notifications" }

  public static let summaryKeys = ["notifications", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("notifications", state.choice?.rawValue ?? "undecided"),
      SummaryItem("loading", state.isLoading),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .action("allow", help: "Allow notifications and finish onboarding (account.completeOnboarding).", .chose(.allowed)),
    .action("not-now", help: "Finish onboarding without notifications.", .chose(.off)),
    .action(
      "retry",
      help: "Save onboarding again after a failure.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retryTapped
    ),
  ]
}
