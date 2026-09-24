import AuthClient
import ComposableArchitecture
import Models

/// Create an account ("Signup"). Validation issues are shown inline. A successful registration emails a code and
/// moves on to email verification; "Sign up with Google" signs in directly.
@Reducer
public struct Register {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var name: String
    public var email: String
    public var password: String
    public var confirm: String
    public var showPassword: Bool
    public var showConfirm: Bool
    public var acceptedTerms: Bool
    public var isLoading: Bool
    public var isGoogleLoading: Bool
    public var error: AuthError?

    public init(
      name: String = "",
      email: String = "",
      password: String = "",
      confirm: String = "",
      showPassword: Bool = false,
      showConfirm: Bool = false,
      acceptedTerms: Bool = false,
      isLoading: Bool = false,
      isGoogleLoading: Bool = false,
      error: AuthError? = nil
    ) {
      self.name = name
      self.email = email
      self.password = password
      self.confirm = confirm
      self.showPassword = showPassword
      self.showConfirm = showConfirm
      self.acceptedTerms = acceptedTerms
      self.isLoading = isLoading
      self.isGoogleLoading = isGoogleLoading
      self.error = error
    }

    /// Validation problems for fields that are not empty, e.g. `email`, `passwordTooShort`, `confirmMismatch`.
    public var issues: [ValidationIssue] {
      var issues: [ValidationIssue] = []
      if !email.isEmpty, !isValidEmail(email) { issues.append(.email) }
      if !password.isEmpty { issues += passwordIssues(password).map(ValidationIssue.init) }
      if !confirm.isEmpty, confirm != password { issues.append(.confirmMismatch) }
      return issues
    }

    /// Issues shown under the email, password and confirm fields.
    public var emailFieldIssues: [ValidationIssue] { issues.filter { $0 == .email } }
    public var passwordFieldIssues: [ValidationIssue] { issues.filter { $0 != .email && $0 != .confirmMismatch } }
    public var confirmFieldIssues: [ValidationIssue] { issues.filter { $0 == .confirmMismatch } }

    /// A sign-up (form or Google) is in flight.
    public var isBusy: Bool { isLoading || isGoogleLoading }

    public var canSubmit: Bool {
      !name.trimmingCharacters(in: .whitespaces).isEmpty
        && isValidEmail(email)
        && isStrongPassword(password)
        && confirm == password
        && acceptedTerms
        && !isBusy
    }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case submitTapped
    case registerResponse(AuthError?)
    case googleTapped
    case googleResponse(Result<Session, AuthError>)
    /// The back button and "Sign in here".
    case backTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The account was created; verify the emailed code next.
      case verifyEmail(email: String)
      /// Signed up with Google.
      case authenticated(Session)
    }
  }

  @Dependency(\.authClient) var authClient
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.showPassword), .binding(\.showConfirm):
        return .none

      case .binding:
        state.error = nil
        return .none

      case .submitTapped:
        guard state.canSubmit else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, name = state.name, email = state.email, password = state.password] send in
          do {
            try await authClient.register(name: name, email: email, password: password)
            await send(.registerResponse(nil))
          } catch {
            await send(.registerResponse(AuthError(error)))
          }
        }

      case .registerResponse(nil):
        state.isLoading = false
        return .send(.delegate(.verifyEmail(email: state.email)))

      case let .registerResponse(error?):
        state.isLoading = false
        state.error = error
        return .none

      case .googleTapped:
        guard !state.isBusy else { return .none }
        state.isGoogleLoading = true
        state.error = nil
        return .run { [authClient] send in
          do {
            await send(.googleResponse(.success(try await authClient.signInWithGoogle())))
          } catch {
            await send(.googleResponse(.failure(AuthError(error))))
          }
        }

      case let .googleResponse(.success(session)):
        state.isGoogleLoading = false
        return .send(.delegate(.authenticated(session)))

      case let .googleResponse(.failure(error)):
        state.isGoogleLoading = false
        state.error = error
        return .none

      case .backTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
