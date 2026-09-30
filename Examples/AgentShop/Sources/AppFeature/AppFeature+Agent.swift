import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import HomeFeature
import OnboardingFeature

extension AppFeature: AgentContainer {
  static let loginAsHelp = "Save a seeded account's session and go straight home."
  static let resetHelp = "Restart from a fresh launch (keeps the saved session and the mock data)."

  /// Root commands, available on every screen: `inheritingCommands` adds them to the active screen and the registry.
  public static let inheritedCommands: [AgentCommand<State, Action>] = [
    .choice(
      "login-as",
      [("alice", MockAccounts.alice.user), ("bob", MockAccounts.bob.user)],
      help: loginAsHelp
    ) { .loginAs(MockAccounts.session(for: $0)) },
    .action("reset", help: resetHelp, .reset),
  ]

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
    // `back` when no container has anything to pop: a clear error instead of "unknown command".
    return inheritingCommands(screen, state).appendingBackFallback(source: containerName)
  }

  public static var registry: [ScreenDoc] {
    let screens =
      [ScreenDoc(path: "launching", screen: "AppFeature", commands: [], summaryKeys: [])]
      + AuthFlow.registry
      + OnboardingFlow.registry
      + HomeTabs.registry
    return inheritingCommands(screens).map { $0.inheriting([.backFallback(source: containerName)]) }
  }
}
