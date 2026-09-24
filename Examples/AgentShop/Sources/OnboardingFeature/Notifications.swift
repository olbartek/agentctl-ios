import AccountClient
import ComposableArchitecture
import Models

/// The last onboarding step: allow notifications or not. Either answer saves the whole onboarding
/// (`account.completeOnboarding`); a failure keeps the shopper here with `retry`.
@Reducer
public struct Notifications {
  public enum Choice: String, Equatable, Sendable {
    case allowed
    case off
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    /// What the earlier steps collected, saved together with the choice.
    public var interests: [ProductCategory]
    public var address: Address?
    public var choice: Choice?
    public var isLoading: Bool
    public var error: AccountError?

    public init(
      interests: [ProductCategory] = [],
      address: Address? = nil,
      choice: Choice? = nil,
      isLoading: Bool = false,
      error: AccountError? = nil
    ) {
      self.interests = interests
      self.address = address
      self.choice = choice
      self.isLoading = isLoading
      self.error = error
    }
  }

  public enum Action: Sendable {
    case chose(Choice)
    case retryTapped
    case completed(Result<AccountProfile, AccountError>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case finished(AccountProfile)
    }
  }

  @Dependency(\.accountClient) var accountClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .chose(choice):
        guard !state.isLoading else { return .none }
        state.choice = choice
        return save(&state)

      case .retryTapped:
        guard state.error != nil, !state.isLoading else { return .none }
        return save(&state)

      case let .completed(.success(profile)):
        state.isLoading = false
        return .send(.delegate(.finished(profile)))

      case let .completed(.failure(error)):
        state.isLoading = false
        state.error = error
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func save(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.error = nil
    let answers = OnboardingAnswers(
      interests: state.interests, address: state.address, notifications: state.choice == .allowed
    )
    return .run { [accountClient] send in
      do {
        await send(.completed(.success(try await accountClient.completeOnboarding(answers))))
      } catch {
        await send(.completed(.failure(AccountError(error))))
      }
    }
  }
}
