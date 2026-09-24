import AuthClient
import ComposableArchitecture
import Models

/// Email and password login, or "Sign in with Google". Links to OTP login, registration and forgot password.
///
/// "Keep me signed in" is read by the container when any auth screen signs in: when it is off, the session is not
/// restored on the next launch. An unverified account is sent to email verification instead of signing in.
@Reducer
public struct Login {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var email: String
    public var password: String
    public var showPassword: Bool
    public var keepSignedIn: Bool
    public var isLoading: Bool
    public var isGoogleLoading: Bool
    public var error: AuthError?

    public init(
      email: String = "",
      password: String = "",
      showPassword: Bool = false,
      keepSignedIn: Bool = true,
      isLoading: Bool = false,
      isGoogleLoading: Bool = false,
      error: AuthError? = nil
    ) {
      self.email = email
      self.password = password
      self.showPassword = showPassword
      self.keepSignedIn = keepSignedIn
      self.isLoading = isLoading
      self.isGoogleLoading = isGoogleLoading
      self.error = error
    }

    /// A sign-in (password or Google) is in flight.
    public var isBusy: Bool { isLoading || isGoogleLoading }

    /// Submit is enabled only for a valid email and a non-empty password.
    public var canSubmit: Bool { isValidEmail(email) && !password.isEmpty && !isBusy }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case submitTapped
    case googleTapped
    case loginResponse(Result<Session, AuthError>)
    case useOTPTapped
    case registerTapped
    case forgotPasswordTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case authenticated(Session)
      case useOTP(email: String)
      case register
      case forgotPassword(email: String)
      /// The account exists but its email was never verified.
      case verifyEmail(email: String)
    }
  }

  @Dependency(\.authClient) var authClient

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.showPassword), .binding(\.keepSignedIn):
        return .none

      case .binding:
        state.error = nil
        return .none

      case .submitTapped:
        guard state.canSubmit else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email, password = state.password] send in
          do {
            await send(.loginResponse(.success(try await authClient.login(email: email, password: password))))
          } catch {
            await send(.loginResponse(.failure(AuthError(error))))
          }
        }

      case .googleTapped:
        guard !state.isBusy else { return .none }
        state.isGoogleLoading = true
        state.error = nil
        return .run { [authClient] send in
          do {
            await send(.loginResponse(.success(try await authClient.signInWithGoogle())))
          } catch {
            await send(.loginResponse(.failure(AuthError(error))))
          }
        }

      case let .loginResponse(.success(session)):
        state.isLoading = false
        state.isGoogleLoading = false
        return .send(.delegate(.authenticated(session)))

      case .loginResponse(.failure(.emailNotVerified)):
        state.isLoading = false
        state.isGoogleLoading = false
        return .send(.delegate(.verifyEmail(email: state.email)))

      case let .loginResponse(.failure(error)):
        state.isLoading = false
        state.isGoogleLoading = false
        state.error = error
        return .none

      case .useOTPTapped:
        return .send(.delegate(.useOTP(email: state.email)))

      case .registerTapped:
        return .send(.delegate(.register))

      case .forgotPasswordTapped:
        return .send(.delegate(.forgotPassword(email: state.email)))

      case .delegate:
        return .none
      }
    }
  }
}
