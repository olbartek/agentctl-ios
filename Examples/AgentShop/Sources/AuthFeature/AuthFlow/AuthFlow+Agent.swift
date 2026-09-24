import AgentCtlCore
import ComposableArchitecture

extension AuthFlow: AgentContainer {
  static let backHelp = "Go back to the previous screen."

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    guard let id = state.path.ids.last, let top = state.path[id: id] else {
      return Login.activeScreen(state.login).map { .login($0) }
    }
    let child: ActiveScreen<Action> =
      switch top {
      case let .otpLogin(screen):
        OTPLogin.activeScreen(screen).map { .path(.element(id: id, action: .otpLogin($0))) }
      case let .register(screen):
        Register.activeScreen(screen).map { .path(.element(id: id, action: .register($0))) }
      case let .verifyEmail(screen):
        VerifyEmail.activeScreen(screen).map { .path(.element(id: id, action: .verifyEmail($0))) }
      case let .forgotPassword(screen):
        ForgotPassword.activeScreen(screen).map { .path(.element(id: id, action: .forgotPassword($0))) }
      }
    let back = AgentCommand<State, Action>
      .action("back", help: backHelp, .path(.popFrom(id: id)))
      .resolve(state, source: "AuthFlow")
    return child.identified(by: id.debugDescription).appending([back])
  }

  public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "AuthFlow")
    let pushed = OTPLogin.screenDocs + Register.screenDocs + VerifyEmail.screenDocs + ForgotPassword.screenDocs
    return Login.screenDocs + pushed.map { $0.inheriting([back]) }
  }
}
