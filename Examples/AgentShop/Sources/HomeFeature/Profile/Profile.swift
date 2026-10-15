import AgentCtlCore
import ComposableArchitecture
import DeviceClients
import Models

/// The signed-in user. Logging out asks for confirmation first.
///
/// Order updates need permission to send notifications: turning them on asks for it, and a denial turns them off
/// again with `notificationsDenied`. Face ID sign-in is turned on by passing Face ID once; the account is then kept
/// for the login screen's `face-id`.
@Reducer
public struct Profile {
  public enum Error: String, Equatable, Sendable {
    case notificationsDenied
    case biometryFailed
    case biometryUnavailable
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var user: User
    /// The signed-in session, kept for Face ID sign-in.
    public var session: Session?
    public var orderUpdates: Bool
    public var faceID: Bool
    public var error: Error?
    @Presents public var alert: AlertState<Action.Alert>?

    public init(
      user: User,
      session: Session? = nil,
      orderUpdates: Bool = false,
      faceID: Bool = false,
      error: Error? = nil,
      alert: AlertState<Action.Alert>? = nil
    ) {
      self.user = user
      self.session = session
      self.orderUpdates = orderUpdates
      self.faceID = faceID
      self.error = error
      self.alert = alert
    }
  }

  public enum Action: Sendable {
    case onAppear
    case orderUpdatesToggled(Bool)
    case notificationsAnswered(PermissionStatus)
    case faceIDToggled(Bool)
    case faceIDAnswered(BiometryResult)
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

  @Dependency(\.notificationsClient) var notificationsClient
  @Dependency(\.biometricsClient) var biometricsClient
  @Dependency(\.faceIDVault) var faceIDVault

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        state.faceID = faceIDVault.session?.user == state.user
        return .none

      case let .orderUpdatesToggled(on):
        state.error = nil
        guard on else {
          state.orderUpdates = false
          return .none
        }
        return .run { [notificationsClient] send in
          await send(.notificationsAnswered(await notificationsClient.requestAuthorization()))
        }

      case let .notificationsAnswered(status):
        state.orderUpdates = status == .granted || status == .limited
        state.error = state.orderUpdates ? nil : .notificationsDenied
        return .none

      case let .faceIDToggled(on):
        state.error = nil
        guard on else {
          faceIDVault.disable()
          state.faceID = false
          return .none
        }
        return .run { [biometricsClient] send in
          await send(.faceIDAnswered(await biometricsClient.authenticate()))
        }

      case let .faceIDAnswered(result):
        switch result {
        case .success:
          if let session = state.session { faceIDVault.enable(session) }
          state.faceID = true
        case .failure:
          state.error = .biometryFailed
        case .unavailable:
          state.error = .biometryUnavailable
        }
        return .none

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
