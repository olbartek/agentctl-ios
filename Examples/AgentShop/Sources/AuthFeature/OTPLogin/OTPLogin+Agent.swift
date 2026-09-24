import AgentCtlCore
import ComposableArchitecture

extension OTPLogin: AgentScreen {
  public static let screenPaths = ["auth/otp/email", "auth/otp/code"]

  public static func screenPath(_ state: State) -> String {
    switch state.step {
    case .email: "auth/otp/email"
    case .code: "auth/otp/code"
    }
  }

  public static let summaryKeys = ["email", "canSend", "resendIn", "attemptsLeft", "canVerify", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    switch state.step {
    case .email:
      [
        SummaryItem("email", state.email),
        SummaryItem("canSend", state.canSend),
        SummaryItem("loading", state.isLoading),
      ]
    case .code:
      [
        SummaryItem("email", state.email),
        SummaryItem("resendIn", state.resendIn),
        SummaryItem("attemptsLeft", state.attemptsLeft),
        SummaryItem("canVerify", state.canVerify),
        SummaryItem("loading", state.isLoading),
      ]
    }
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("email", help: "Set the email field.", paths: ["auth/otp/email"]) { .binding(.set(\.email, $0)) },
    .action(
      "send",
      help: "Email a one-time code.",
      paths: ["auth/otp/email"],
      gate: CommandGate(hint: "canSend=false") { $0.canSend },
      .sendTapped
    ),
    .text("code", argument: "<digits>", help: "Type the 6-digit code.", paths: ["auth/otp/code"]) {
      .binding(.set(\.code, $0))
    },
    .action(
      "verify",
      help: "Verify the code and log in.",
      paths: ["auth/otp/code"],
      gate: CommandGate(hint: "canVerify=false") { $0.canVerify },
      .verifyTapped
    ),
    // Not gated on purpose: while `resendIn > 0` the reducer answers with `error=resendNotAvailable`.
    .action("resend", help: "Send a new code (blocked while resendIn > 0).", paths: ["auth/otp/code"], .resendTapped),
  ]
}
