import AccountClient
import AuthFeature
import ComposableArchitecture
import HomeFeature
import Models
import OnboardingFeature
import SessionClient

/// The root: launching, then auth, onboarding (once, for a new account) or home.
@Reducer
public struct AppFeature {
  @ObservableState
  @CasePathable
  public enum State: Equatable, Sendable {
    case launching
    case auth(AuthFlow.State)
    case onboarding(OnboardingFlow.State)
    case home(HomeTabs.State)
  }

  public enum Action: Sendable {
    case appeared
    case sessionLoaded(Session?)
    case auth(AuthFlow.Action)
    case onboarding(OnboardingFlow.Action)
    case home(HomeTabs.Action)
    /// Signed in and the account's profile is loaded: onboarding first if it still needs it, else home.
    case signedIn(Session, needsOnboarding: Bool)
    case signedOut
    /// Saves a seeded account's session and goes straight home (`login-as`).
    case loginAs(Session)
    /// Restarts from a fresh launch: the saved session and the mock backends are kept.
    case reset
  }

  @Dependency(\.sessionClient) var sessionClient
  @Dependency(\.accountClient) var accountClient
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        guard case .launching = state else { return .none }
        return .run { [sessionClient] send in
          await send(.sessionLoaded(await sessionClient.current()))
        }

      case let .sessionLoaded(session):
        state = session.map { .home(HomeTabs.State(id: uuid(), session: $0)) } ?? .auth(AuthFlow.State())
        return .none

      case let .auth(.delegate(.authenticated(session, remember))):
        return signIn(session, remember: remember)

      case let .loginAs(session):
        return signIn(session, remember: true)

      case let .signedIn(session, needsOnboarding):
        state = needsOnboarding
          ? .onboarding(OnboardingFlow.State(session: session))
          : .home(HomeTabs.State(id: uuid(), session: session))
        return .none

      case let .onboarding(.delegate(.finished(session))):
        state = .home(HomeTabs.State(id: uuid(), session: session))
        return .none

      case .home(.delegate(.loggedOut)):
        return .run { [sessionClient] send in
          await sessionClient.clear()
          await send(.signedOut)
        }

      case .signedOut:
        state = .auth(AuthFlow.State())
        return .none

      case .reset:
        // The launching screen appears again and sends `.appeared`, which restores the session.
        state = .launching
        return .none

      case .auth, .onboarding, .home:
        return .none
      }
    }
    .ifCaseLet(\.auth, action: \.auth) {
      AuthFlow()
    }
    .ifCaseLet(\.onboarding, action: \.onboarding) {
      OnboardingFlow()
    }
    .ifCaseLet(\.home, action: \.home) {
      HomeTabs()
    }
  }

  /// Saves the session (restored on the next launch only when `remember` is set), then asks the account server
  /// whether this account still needs onboarding. If that fails the shopper goes home: onboarding is never a
  /// reason to lock someone out.
  private func signIn(_ session: Session, remember: Bool) -> Effect<Action> {
    .run { [sessionClient, accountClient] send in
      await sessionClient.save(session, remember)
      let profile = try? await accountClient.fetchProfile()
      await send(.signedIn(session, needsOnboarding: profile?.needsOnboarding ?? false))
    }
  }
}

extension AppFeature.State {
  public init() {
    self = .launching
  }
}
