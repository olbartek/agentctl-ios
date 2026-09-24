import ComposableArchitecture
import Models

/// Onboarding, once per new account: welcome → interests → address → notifications, then home.
///
/// A linear flow rather than a navigation stack: each step's state is kept, so going back to interests shows what
/// was picked.
@Reducer
public struct OnboardingFlow {
  public enum Step: String, CaseIterable, Equatable, Sendable {
    case welcome
    case interests
    case address
    case notifications
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var session: Session
    public var step: Step
    public var welcome: Welcome.State
    public var interests: Interests.State
    public var address: AddressForm.State
    public var notifications: Notifications.State

    public init(
      session: Session,
      step: Step = .welcome,
      welcome: Welcome.State = Welcome.State(),
      interests: Interests.State = Interests.State(),
      address: AddressForm.State = AddressForm.State(),
      notifications: Notifications.State = Notifications.State()
    ) {
      self.session = session
      self.step = step
      self.welcome = welcome
      self.interests = interests
      self.address = address
      self.notifications = notifications
    }
  }

  public enum Action: Sendable {
    case welcome(Welcome.Action)
    case interests(Interests.Action)
    case address(AddressForm.Action)
    case notifications(Notifications.Action)
    /// The back button: the previous step.
    case backTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case finished(Session)
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.welcome, action: \.welcome) { Welcome() }
    Scope(state: \.interests, action: \.interests) { Interests() }
    Scope(state: \.address, action: \.address) { AddressForm() }
    Scope(state: \.notifications, action: \.notifications) { Notifications() }
    Reduce { state, action in
      switch action {
      case .welcome(.delegate(.finished)):
        state.step = .interests
        return .none

      case let .interests(.delegate(.chose(interests))):
        state.notifications.interests = interests
        state.step = .address
        return .none

      case let .address(.delegate(.finished(address))):
        state.notifications.address = address
        state.step = .notifications
        return .none

      case .notifications(.delegate(.finished)):
        return .send(.delegate(.finished(state.session)))

      case .backTapped:
        switch state.step {
        case .welcome: break
        case .interests: state.step = .welcome
        case .address: state.step = .interests
        case .notifications:
          // Not while the answers are being saved.
          guard !state.notifications.isLoading else { break }
          state.step = .address
        }
        return .none

      case .welcome, .interests, .address, .notifications, .delegate:
        return .none
      }
    }
  }
}
