import AgentCtlCore
import ComposableArchitecture
import Models

extension Register: AgentScreen {
  public static let screenPaths = ["auth/register"]

  public static func screenPath(_ state: State) -> String { "auth/register" }

  public static let summaryKeys = ["email", "terms", "revealed", "issues", "canSubmit", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    let revealed = [state.showPassword ? "password" : nil, state.showConfirm ? "confirm" : nil].compactMap { $0 }
    return [
      SummaryItem("email", state.email),
      SummaryItem("terms", state.acceptedTerms),
      SummaryItem("revealed", revealed.isEmpty ? "none" : revealed.joined(separator: ",")),
      SummaryItem("issues", ValidationIssue.summary(state.issues)),
      SummaryItem("canSubmit", state.canSubmit),
      SummaryItem("loading", state.isBusy),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("name", help: "Set the full name field.") { .binding(.set(\.name, $0)) },
    .text("email", help: "Set the email field.") { .binding(.set(\.email, $0)) },
    .text("password", help: "Set the password field.") { .binding(.set(\.password, $0)) },
    .text("confirm", help: "Set the confirm-password field.") { .binding(.set(\.confirm, $0)) },
    .onOff("show-password", help: "Show or hide the password.") { .binding(.set(\.showPassword, $0)) },
    .onOff("show-confirm", help: "Show or hide the confirm-password field.") { .binding(.set(\.showConfirm, $0)) },
    .onOff("terms", help: "Accept or decline the terms.") { .binding(.set(\.acceptedTerms, $0)) },
    .action(
      "submit",
      help: "Create the account; a verification code is emailed (verify it next).",
      gate: CommandGate(hint: "canSubmit=false") { $0.canSubmit },
      .submitTapped
    ),
    .action(
      "google",
      help: "Sign up with Google (the mock signs in as becca@gmail.com).",
      gate: CommandGate(hint: "loading=true") { !$0.isBusy },
      .googleTapped
    ),
  ]
}
