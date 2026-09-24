import AgentCtlCore
import ComposableArchitecture

extension VerifyEmail: AgentScreen {
  public static let screenPaths = ["auth/register/verify"]

  public static func screenPath(_ state: State) -> String { "auth/register/verify" }

  public static let summaryKeys = ["email", "resendIn", "canVerify", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("email", state.email),
      SummaryItem("resendIn", state.resendIn),
      SummaryItem("canVerify", state.canVerify),
      SummaryItem("loading", state.isLoading),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let onAppear: Action? = .onAppear

  public static let commands: [AgentCommand<State, Action>] = [
    .text("code", argument: "<digits>", help: "Type the 6-digit verification code.") { .binding(.set(\.code, $0)) },
    .action(
      "verify",
      help: "Verify the email and sign in (\"Create Account\").",
      gate: CommandGate(hint: "canVerify=false") { $0.canVerify },
      .verifyTapped
    ),
    // Not gated on purpose: while `resendIn > 0` the reducer answers with `error=resendNotAvailable`.
    .action("resend", help: "Email a new code (blocked while resendIn > 0).", .resendTapped),
  ]
}
