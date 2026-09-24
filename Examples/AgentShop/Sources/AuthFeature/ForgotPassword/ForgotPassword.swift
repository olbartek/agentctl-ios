import AuthClient
import ComposableArchitecture
import Models

/// Forgot password: request a reset code, then enter the code with a new password, then go back to login.
///
/// Requesting always succeeds, so the app never reveals which accounts exist.
@Reducer
public struct ForgotPassword {
  public enum Step: String, Equatable, Sendable {
    case email
    case reset
    case done
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var step: Step
    public var email: String
    public var code: String
    public var password: String
    public var confirm: String
    public var showPassword: Bool
    public var showConfirm: Bool
    public var isLoading: Bool
    public var error: AuthError?

    public init(
      step: Step = .email,
      email: String = "",
      code: String = "",
      password: String = "",
      confirm: String = "",
      showPassword: Bool = false,
      showConfirm: Bool = false,
      isLoading: Bool = false,
      error: AuthError? = nil
    ) {
      self.step = step
      self.email = email
      self.code = code
      self.password = password
      self.confirm = confirm
      self.showPassword = showPassword
      self.showConfirm = showConfirm
      self.isLoading = isLoading
      self.error = error
    }

    public var canSend: Bool { isValidEmail(email) && !isLoading }

    public var issues: [ValidationIssue] {
      var issues: [ValidationIssue] = []
      if !password.isEmpty { issues += passwordIssues(password).map(ValidationIssue.init) }
      if !confirm.isEmpty, confirm != password { issues.append(.confirmMismatch) }
      return issues
    }

    /// Issues shown under the new-password and confirm fields.
    public var passwordFieldIssues: [ValidationIssue] { issues.filter { $0 != .confirmMismatch } }
    public var confirmFieldIssues: [ValidationIssue] { issues.filter { $0 == .confirmMismatch } }

    public var canSubmit: Bool {
      code.count == 6 && isStrongPassword(password) && confirm == password && !isLoading
    }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case sendTapped
    case requestResponse(AuthError?)
    case submitTapped
    case resetResponse(AuthError?)
    case backToLoginTapped
    /// The back button and "Login to your account".
    case backTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// The password was reset; go back to login with this email prefilled.
      case passwordReset(email: String)
    }
  }

  @Dependency(\.authClient) var authClient
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

      case .binding(\.showPassword), .binding(\.showConfirm):
        return .none

      case .binding:
        state.error = nil
        return .none

      case .sendTapped:
        guard state.canSend else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email] send in
          do {
            try await authClient.requestPasswordReset(email: email)
            await send(.requestResponse(nil))
          } catch {
            await send(.requestResponse(AuthError(error)))
          }
        }

      case .requestResponse(nil):
        state.isLoading = false
        state.step = .reset
        return .none

      case let .requestResponse(error?):
        state.isLoading = false
        state.error = error
        return .none

      case .submitTapped:
        guard state.canSubmit else { return .none }
        state.isLoading = true
        state.error = nil
        return .run { [authClient, email = state.email, code = state.code, password = state.password] send in
          do {
            try await authClient.resetPassword(email: email, code: code, newPassword: password)
            await send(.resetResponse(nil))
          } catch {
            await send(.resetResponse(AuthError(error)))
          }
        }

      case .resetResponse(nil):
        state.isLoading = false
        state.step = .done
        state.code = ""
        state.password = ""
        state.confirm = ""
        state.showPassword = false
        state.showConfirm = false
        return .none

      case let .resetResponse(error?):
        state.isLoading = false
        state.error = error
        return .none

      case .backToLoginTapped:
        return .send(.delegate(.passwordReset(email: state.email)))

      case .backTapped:
        return .run { [dismiss] _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
