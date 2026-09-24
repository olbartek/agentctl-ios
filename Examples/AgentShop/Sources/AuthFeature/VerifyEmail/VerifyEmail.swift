import AuthClient
import ComposableArchitecture
import Models

/// Verify a new account's email: enter the 6-digit code that registration emailed ("Create Account").
///
/// Resend is blocked for 30 s after each email; the countdown starts when the screen appears. Opened from login for
/// an unverified account, no code was just sent, so resend is available at once.
@Reducer
public struct VerifyEmail {
  public static let resendCooldown = 30

  @ObservableState
  public struct State: Equatable, Sendable {
    public var email: String
    public var code: String
    public var resendIn: Int
    public var isLoading: Bool
    public var error: AuthError?

    public init(
      email: String,
      code: String = "",
      resendIn: Int = VerifyEmail.resendCooldown,
      isLoading: Bool = false,
      error: AuthError? = nil
    ) {
      self.email = email
      self.code = code
      self.resendIn = resendIn
      self.isLoading = isLoading
      self.error = error
    }

    public var canVerify: Bool { code.count == 6 && !isLoading }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case onAppear
    case tick
    case verifyTapped
    case verifyResponse(Result<Session, AuthError>)
    case resendTapped
    case resendResponse(AuthError?)
    case backTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case authenticated(Session)
    }
  }

  enum CancelID { case countdown }

  @Dependency(\.authClient) var authClient
  @Dependency(\.continuousClock) var clock
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.code):
        state.code = String(state.code.filter(\.isNumber).prefix(6))
        state.error = nil
        return .none

      case .binding:
        return .none

      case .onAppear:
        return state.resendIn > 0 ? countdown() : .none

      case .tick:
        state.resendIn = max(0, state.resendIn - 1)
        return state.resendIn == 0 ? .cancel(id: CancelID.countdown) : .none

      case .verifyTapped:
        guard state.canVerify else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email, code = state.code] send in
          do {
            await send(.verifyResponse(.success(try await authClient.verifyEmail(email: email, code: code))))
          } catch {
            await send(.verifyResponse(.failure(AuthError(error))))
          }
        }

      case let .verifyResponse(.success(session)):
        state.isLoading = false
        return .merge(
          .cancel(id: CancelID.countdown),
          .send(.delegate(.authenticated(session)))
        )

      case let .verifyResponse(.failure(error)):
        state.isLoading = false
        state.error = error
        if error == .invalidCode {
          state.code = ""
        }
        return .none

      case .resendTapped:
        guard state.resendIn == 0 else {
          state.error = .resendNotAvailable
          return .none
        }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email] send in
          do {
            try await authClient.resendVerification(email: email)
            await send(.resendResponse(nil))
          } catch {
            await send(.resendResponse(AuthError(error)))
          }
        }

      case .resendResponse(nil):
        state.isLoading = false
        state.code = ""
        state.resendIn = VerifyEmail.resendCooldown
        return countdown()

      case let .resendResponse(error?):
        state.isLoading = false
        state.error = error
        return .none

      case .backTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }

  private func countdown() -> Effect<Action> {
    .run { [clock] send in
      for await _ in clock.timer(interval: .seconds(1)) {
        await send(.tick)
      }
    }
    .cancellable(id: CancelID.countdown, cancelInFlight: true)
  }
}
