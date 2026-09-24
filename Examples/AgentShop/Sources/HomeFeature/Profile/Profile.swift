import ComposableArchitecture
import Models

/// The signed-in user. Logging out asks for confirmation first.
@Reducer
public struct Profile {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var user: User
    @Presents public var alert: AlertState<Action.Alert>?

    public init(user: User, alert: AlertState<Action.Alert>? = nil) {
      self.user = user
      self.alert = alert
    }
  }

  public enum Action: Sendable {
    case logoutTapped
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    public enum Alert: Equatable, Sendable {
      case confirmLogout
    }

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case loggedOut
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .logoutTapped:
        state.alert = .confirmLogout
        return .none

      case .alert(.presented(.confirmLogout)):
        return .send(.delegate(.loggedOut))

      case .alert, .delegate:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

extension AlertState where Action == Profile.Action.Alert {
  public static var confirmLogout: Self {
    AlertState {
      TextState("Log out?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmLogout) {
        TextState("Log out")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("You will need to sign in again.")
    }
  }
}
