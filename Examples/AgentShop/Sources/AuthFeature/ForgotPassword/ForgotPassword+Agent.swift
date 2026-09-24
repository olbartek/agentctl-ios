import AgentCtlCore
import ComposableArchitecture
import Models

extension ForgotPassword: AgentScreen {
  public static let screenPaths = ["auth/forgot/email", "auth/forgot/reset", "auth/forgot/done"]

  public static func screenPath(_ state: State) -> String {
    "auth/forgot/\(state.step.rawValue)"
  }

  public static let summaryKeys = ["email", "canSend", "revealed", "issues", "canSubmit", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    switch state.step {
    case .email:
      [
        SummaryItem("email", state.email),
        SummaryItem("canSend", state.canSend),
        SummaryItem("loading", state.isLoading),
      ]
    case .reset:
      [
        SummaryItem("email", state.email),
        SummaryItem("revealed", revealed(state)),
        SummaryItem("issues", ValidationIssue.summary(state.issues)),
        SummaryItem("canSubmit", state.canSubmit),
        SummaryItem("loading", state.isLoading),
      ]
    case .done:
      [SummaryItem("email", state.email)]
    }
  }

  static func revealed(_ state: State) -> String {
    let fields = [state.showPassword ? "password" : nil, state.showConfirm ? "confirm" : nil].compactMap { $0 }
    return fields.isEmpty ? "none" : fields.joined(separator: ",")
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("email", help: "Set the email field.", paths: ["auth/forgot/email"]) { .binding(.set(\.email, $0)) },
    .action(
      "send",
      help: "Request a reset code (always succeeds).",
      paths: ["auth/forgot/email"],
      gate: CommandGate(hint: "canSend=false") { $0.canSend },
      .sendTapped
    ),
    .text("code", argument: "<digits>", help: "Type the 6-digit reset code.", paths: ["auth/forgot/reset"]) {
      .binding(.set(\.code, $0))
    },
    .text("password", help: "Set the new password.", paths: ["auth/forgot/reset"]) { .binding(.set(\.password, $0)) },
    .text("confirm", help: "Confirm the new password.", paths: ["auth/forgot/reset"]) { .binding(.set(\.confirm, $0)) },
    .onOff("show-password", help: "Show or hide the new password.", paths: ["auth/forgot/reset"]) {
      .binding(.set(\.showPassword, $0))
    },
    .onOff("show-confirm", help: "Show or hide the confirm field.", paths: ["auth/forgot/reset"]) {
      .binding(.set(\.showConfirm, $0))
    },
    .action(
      "submit",
      help: "Reset the password.",
      paths: ["auth/forgot/reset"],
      gate: CommandGate(hint: "canSubmit=false") { $0.canSubmit },
      .submitTapped
    ),
    .action("to-login", help: "Go back to login with the email prefilled.", paths: ["auth/forgot/done"], .backToLoginTapped),
  ]
}
