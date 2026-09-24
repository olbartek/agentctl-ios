import AuthFeature
import ComposableArchitecture
import HomeFeature
import Models
import SessionClient

/// The root: launching, then auth or home.
@Reducer
public struct AppFeature {
  @ObservableState
  @CasePathable
  public enum State: Equatable, Sendable {
    case launching
    case auth(AuthFlow.State)
    case home(HomeTabs.State)
  }

  public enum Action: Sendable {
    case appeared
    case sessionLoaded(Session?)
    case auth(AuthFlow.Action)
    case home(HomeTabs.Action)
    case signedIn(Session)
    case signedOut
    /// Saves a seeded account's session and goes straight home (`login-as`).
    case loginAs(Session)
    /// Restarts from a fresh launch: the saved session and the mock backends are kept.
    case reset
  }

  @Dependency(\.sessionClient) var sessionClient
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

      case let .signedIn(session):
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

      case .auth, .home:
        return .none
      }
    }
    .ifCaseLet(\.auth, action: \.auth) {
      AuthFlow()
    }
    .ifCaseLet(\.home, action: \.home) {
      HomeTabs()
    }
  }

  /// Saves the session (restored on the next launch only when `remember` is set) and goes home.
  private func signIn(_ session: Session, remember: Bool) -> Effect<Action> {
    .run { [sessionClient] send in
      await sessionClient.save(session, remember)
      await send(.signedIn(session))
    }
  }
}

extension AppFeature.State {
  public init() {
    self = .launching
  }
}
