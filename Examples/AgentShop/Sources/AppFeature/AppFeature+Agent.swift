import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import HomeFeature
import OnboardingFeature

extension AppFeature: AgentContainer {
  static let loginAsHelp = "Save a seeded account's session and go straight home."
  static let resetHelp = "Restart from a fresh launch (keeps the saved session and the mock data)."
  static let backHelp = "Go back to the previous screen."

  /// Root commands, available on every screen.
  static let rootCommands: [AgentCommand<State, Action>] = [
    .parsing("login-as", argument: "<alice|bob>", help: loginAsHelp) { name throws(AgentCommandError) in
      guard let session = MockAccounts.session(named: name) else { throw .invalidArgument("expected alice|bob") }
      return .loginAs(session)
    },
    .action("reset", help: resetHelp, .reset),
  ]

  /// `back` when no container has anything to pop: a clear error instead of "unknown command".
  static func backFallback(path: String) -> ResolvedCommand<Action> {
    ResolvedCommand(name: "back", argument: nil, help: backHelp, source: "AppFeature", disabledReason: nil) {
      (_: String?) throws(AgentCommandError) -> Action in
      throw .notApplicable("nothing to go back to on \(path)")
    }
  }

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    let screen: ActiveScreen<Action> =
      switch state {
      case .launching:
        ActiveScreen(
          path: "launching",
          identity: "launching",
          summary: [],
          errorCode: nil,
          appearAction: .appeared,
          commands: []
        )
      case let .auth(auth):
        AuthFlow.activeScreen(auth).map { .auth($0) }.identified(by: "auth")
      case let .onboarding(onboarding):
        OnboardingFlow.activeScreen(onboarding).map { .onboarding($0) }.identified(by: "onboarding")
      case let .home(home):
        HomeTabs.activeScreen(home).map { .home($0) }
      }
    return screen
      .appending(rootCommands.map { $0.resolve(state, source: "AppFeature") })
      .appending([backFallback(path: screen.path)])
  }

  public static var registry: [ScreenDoc] {
    let back = CommandDoc(
      name: "back",
      argument: nil,
      help: "Fails with 'nothing to go back to' when no screen is pushed.",
      source: "AppFeature"
    )
    let root = rootCommands.map { $0.doc(source: "AppFeature") } + [back]
    let screens =
      [ScreenDoc(path: "launching", screen: "AppFeature", commands: [], summaryKeys: [])]
      + AuthFlow.registry
      + OnboardingFlow.registry
      + HomeTabs.registry
    return screens.map { $0.inheriting(root) }
  }
}
