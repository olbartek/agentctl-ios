import AuthClient
import ComposableArchitecture
import Models

/// Login with a one-time code sent by email: enter the email, then the 6-digit code.
///
/// Resend is blocked for 30 s after each send (`resendIn` counts down on the injected clock). After 3 wrong
/// codes, verifying is disabled until a resend.
@Reducer
public struct OTPLogin {
  public static let resendCooldown = 30
  public static let maxAttempts = 3

  public enum Step: String, Equatable, Sendable {
    case email
    case code
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var step: Step
    public var email: String
    public var code: String
    public var resendIn: Int
    public var attemptsLeft: Int
    public var isLoading: Bool
    public var error: AuthError?

    public init(
      step: Step = .email,
      email: String = "",
      code: String = "",
      resendIn: Int = 0,
      attemptsLeft: Int = OTPLogin.maxAttempts,
      isLoading: Bool = false,
      error: AuthError? = nil
    ) {
      self.step = step
      self.email = email
      self.code = code
      self.resendIn = resendIn
      self.attemptsLeft = attemptsLeft
      self.isLoading = isLoading
      self.error = error
    }

    public var canSend: Bool { isValidEmail(email) && !isLoading }
    public var canVerify: Bool { code.count == 6 && attemptsLeft > 0 && !isLoading }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case sendTapped
    case resendTapped
    case sendResponse(AuthError?)
    case tick
    case verifyTapped
    case verifyResponse(Result<Session, AuthError>)
    /// The back button and "Login with password".
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
        state.error = nil
        return .none

      case .sendTapped:
        guard state.canSend else { return .none }
        return send(&state)

      case .resendTapped:
        guard state.resendIn == 0 else {
          state.error = .resendNotAvailable
          return .none
        }
        return send(&state)

      case .sendResponse(nil):
        state.isLoading = false
        state.step = .code
        state.code = ""
        state.attemptsLeft = Self.maxAttempts
        state.resendIn = Self.resendCooldown
        return .run { [clock] send in
          for await _ in clock.timer(interval: .seconds(1)) {
            await send(.tick)
          }
        }
        .cancellable(id: CancelID.countdown, cancelInFlight: true)

      case let .sendResponse(error?):
        state.isLoading = false
        state.error = error
        return .none

      case .tick:
        state.resendIn = max(0, state.resendIn - 1)
        return state.resendIn == 0 ? .cancel(id: CancelID.countdown) : .none

      case .verifyTapped:
        guard state.canVerify else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email, code = state.code] send in
          do {
            await send(.verifyResponse(.success(try await authClient.verifyOTP(email: email, code: code))))
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
          state.attemptsLeft = max(0, state.attemptsLeft - 1)
          state.code = ""
        }
        return .none

      case .backTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }

  private func send(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.error = nil
    return .run { [authClient, email = state.email] send in
      do {
        try await authClient.sendOTP(email: email)
        await send(.sendResponse(nil))
      } catch {
        await send(.sendResponse(AuthError(error)))
      }
    }
  }
}
