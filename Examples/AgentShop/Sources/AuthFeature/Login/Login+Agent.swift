import AgentCtlCore
import ComposableArchitecture

extension Login: AgentScreen {
  public static let screenPaths = ["auth/login"]

  public static func screenPath(_ state: State) -> String { "auth/login" }

  public static let summaryKeys = ["email", "keepSignedIn", "revealed", "canSubmit", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("email", state.email),
      SummaryItem("keepSignedIn", state.keepSignedIn),
      SummaryItem("revealed", state.showPassword ? "password" : "none"),
      SummaryItem("canSubmit", state.canSubmit),
      SummaryItem("loading", state.isBusy),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("email", help: "Set the email field.") { .binding(.set(\.email, $0)) },
    .text("password", help: "Set the password field.") { .binding(.set(\.password, $0)) },
    .onOff("show-password", help: "Show or hide the password.") { .binding(.set(\.showPassword, $0)) },
    .onOff(
      "keep-signed-in",
      help: "Tick \"Keep me signed in\" (on by default). Off: the session is not restored on relaunch."
    ) { .binding(.set(\.keepSignedIn, $0)) },
    .action(
      "submit",
      help: "Log in with the email and password.",
      gate: CommandGate(hint: "canSubmit=false") { $0.canSubmit },
      .submitTapped
    ),
    .action(
      "google",
      help: "Sign in with Google (the mock signs in as becca@gmail.com).",
      gate: CommandGate(hint: "loading=true") { !$0.isBusy },
      .googleTapped
    ),
    .action("use-otp", help: "Switch to login with a one-time code (keeps the email).", .useOTPTapped),
    .action("register", help: "Open registration (\"Sign up here\").", .registerTapped),
    .action("forgot", help: "Open forgot password (keeps the email).", .forgotPasswordTapped),
  ]
}
