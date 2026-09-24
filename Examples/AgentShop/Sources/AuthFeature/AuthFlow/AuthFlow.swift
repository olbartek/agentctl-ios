import ComposableArchitecture
import Models

/// The auth navigation stack: Login at the root, with OTP login, registration (then email verification) and forgot
/// password pushed on top.
///
/// Every sign-in is reported with Login's "Keep me signed in" choice, whichever screen it came from.
@Reducer
public struct AuthFlow {
  @Reducer
  public enum Path {
    case otpLogin(OTPLogin)
    case register(Register)
    case verifyEmail(VerifyEmail)
    case forgotPassword(ForgotPassword)
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var login: Login.State
    public var path: StackState<Path.State>

    public init(login: Login.State = Login.State(), path: StackState<Path.State> = StackState()) {
      self.login = login
      self.path = path
    }
  }

  public enum Action: Sendable {
    case login(Login.Action)
    case path(StackActionOf<Path>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// Signed in. `remember` is "Keep me signed in": whether to restore the session on the next launch.
      case authenticated(Session, remember: Bool)
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.login, action: \.login) {
      Login()
    }
    Reduce { state, action in
      switch action {
      case let .login(.delegate(delegate)):
        switch delegate {
        case let .authenticated(session):
          return .send(.delegate(.authenticated(session, remember: state.login.keepSignedIn)))
        case let .useOTP(email):
          state.path.append(.otpLogin(OTPLogin.State(email: email)))
        case .register:
          state.path.append(.register(Register.State()))
        case let .forgotPassword(email):
          state.path.append(.forgotPassword(ForgotPassword.State(email: email)))
        case let .verifyEmail(email):
          // No code was just sent, so resend is available at once.
          state.path.append(.verifyEmail(VerifyEmail.State(email: email, resendIn: 0)))
        }
        return .none

      case let .path(.element(_, .register(.delegate(.verifyEmail(email))))):
        state.path.append(.verifyEmail(VerifyEmail.State(email: email)))
        return .none

      case let .path(.element(_, .otpLogin(.delegate(.authenticated(session))))),
        let .path(.element(_, .register(.delegate(.authenticated(session))))),
        let .path(.element(_, .verifyEmail(.delegate(.authenticated(session))))):
        return .send(.delegate(.authenticated(session, remember: state.login.keepSignedIn)))

      case let .path(.element(_, .forgotPassword(.delegate(.passwordReset(email))))):
        state.path.removeAll()
        state.login.email = email
        state.login.password = ""
        state.login.showPassword = false
        state.login.error = nil
        return .none

      case .login, .path, .delegate:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
  }
}

extension AuthFlow.Path.State: Equatable, Sendable {}
extension AuthFlow.Path.Action: Sendable {}
