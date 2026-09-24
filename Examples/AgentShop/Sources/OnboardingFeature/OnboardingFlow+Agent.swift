import AgentCtlCore
import ComposableArchitecture

extension OnboardingFlow: AgentContainer {
  static let backHelp = "Go back to the previous step."

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    let back = AgentCommand<State, Action>.action("back", help: backHelp, .backTapped)
      .resolve(state, source: "OnboardingFlow")
    switch state.step {
    case .welcome:
      // Welcome's own `back` pages the carousel; there is no step before it.
      return Welcome.activeScreen(state.welcome).map { .welcome($0) }
    case .interests:
      return Interests.activeScreen(state.interests).map { .interests($0) }.appending([back])
    case .address:
      return AddressForm.activeScreen(state.address).map { .address($0) }.appending([back])
    case .notifications:
      return Notifications.activeScreen(state.notifications).map { .notifications($0) }.appending([back])
    }
  }

  public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "OnboardingFlow")
    return Welcome.screenDocs
      + (Interests.screenDocs + AddressForm.screenDocs + Notifications.screenDocs).map { $0.inheriting([back]) }
  }
}
