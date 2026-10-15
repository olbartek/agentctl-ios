import AgentCtlCore
import ComposableArchitecture

extension Profile: AgentScreen {
  public static let screenPaths = ["home/profile"]

  public static func screenPath(_ state: State) -> String { "home/profile" }

  public static let summaryKeys = ["name", "email", "orderUpdates", "faceID", "alert"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("name", state.user.name),
      SummaryItem("email", state.user.email),
      SummaryItem("orderUpdates", state.orderUpdates ? "on" : "off"),
      SummaryItem("faceID", state.faceID ? "on" : "off"),
      SummaryItem("alert", state.alert == nil ? "none" : "logout"),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  /// Headlessly there is no view to send this, so the runtime sends it when the screen becomes active.
  public static let onAppear: Action? = .onAppear

  static let alertShown = CommandGate<State>(hint: "alert=none") { $0.alert != nil }

  public static let commands: [AgentCommand<State, Action>] = [
    .onOff(
      "order-updates",
      help: "Turn order updates on (asks for permission to send notifications) or off."
    ) { .orderUpdatesToggled($0) },
    .onOff(
      "face-id",
      help: "Turn Face ID sign-in on (passing Face ID once) or off; the login screen then offers face-id."
    ) { .faceIDToggled($0) },
    .action("logout", help: "Ask to log out (shows a confirmation alert).", .logoutTapped),
    .action("confirm", help: "Confirm logging out in the alert.", gate: alertShown, .alert(.presented(.confirmLogout))),
    .action("dismiss", help: "Dismiss the alert.", gate: alertShown, .alert(.dismiss)),
  ]
}
