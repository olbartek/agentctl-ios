import AgentCtlCore
import ComposableArchitecture

extension Welcome: AgentScreen {
  public static let screenPaths = ["onboarding/welcome"]

  public static func screenPath(_ state: State) -> String { "onboarding/welcome" }

  public static let summaryKeys = ["page", "pages"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [SummaryItem("page", state.page), SummaryItem("pages", Welcome.pageCount)]
  }

  public static let commands: [AgentCommand<State, Action>] = [
    .action("next", help: "The next page; on the last one, go on to interests.", .nextTapped),
    .action("skip", help: "Skip the introduction and go to interests.", .skipTapped),
    // The carousel's own back: the previous page. It shadows the flow's `back`, which has nothing before welcome.
    .action(
      "back",
      help: "The previous page.",
      gate: CommandGate(hint: "page=1") { $0.page > 1 },
      .backTapped
    ),
  ]
}
