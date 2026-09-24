import AgentCtlCore
import ComposableArchitecture

extension Profile: AgentScreen {
  public static let screenPaths = ["home/profile"]

  public static func screenPath(_ state: State) -> String { "home/profile" }

  public static let summaryKeys = ["name", "email", "alert"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("name", state.user.name),
      SummaryItem("email", state.user.email),
      SummaryItem("alert", state.alert == nil ? "none" : "logout"),
    ]
  }

  static let alertShown = CommandGate<State>(hint: "alert=none") { $0.alert != nil }

  public static let commands: [AgentCommand<State, Action>] = [
    .action("logout", help: "Ask to log out (shows a confirmation alert).", .logoutTapped),
    .action("confirm", help: "Confirm logging out in the alert.", gate: alertShown, .alert(.presented(.confirmLogout))),
    .action("dismiss", help: "Dismiss the alert.", gate: alertShown, .alert(.dismiss)),
  ]
}
