import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct ForgotPasswordTests {
  let readyToReset = ForgotPassword.State(
    step: .reset,
    email: "alice@example.com",
    code: "654321",
    password: "NewPass123",
    confirm: "NewPass123"
  )

  @Test func requestAlwaysMovesToReset() async {
    let store = TestStore(initialState: ForgotPassword.State(email: "nobody@example.com")) {
      ForgotPassword()
    } withDependencies: {
      $0.authClient.requestPasswordReset = { _ in }
    }
    await store.send(.sendTapped) { $0.isLoading = true }
    await store.receive(\.requestResponse, nil) {
      $0.isLoading = false
      $0.step = .reset
    }
  }

  @Test func requestNetworkFailure() async {
    let store = TestStore(initialState: ForgotPassword.State(email: "alice@example.com")) {
      ForgotPassword()
    } withDependencies: {
      $0.authClient.requestPasswordReset = { _ in throw AuthError.network }
    }
    await store.send(.sendTapped) { $0.isLoading = true }
    await store.receive(\.requestResponse, .network) {
      $0.isLoading = false
      $0.error = .network
    }
  }

  @Test func resetThenBackToLogin() async {
    let store = TestStore(initialState: readyToReset) {
      ForgotPassword()
    } withDependencies: {
      $0.authClient.resetPassword = { email, code, password in
        guard email == "alice@example.com", code == "654321", password == "NewPass123" else {
          throw AuthError.invalidCode
        }
      }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.resetResponse, nil) {
      $0.isLoading = false
      $0.step = .done
      $0.code = ""
      $0.password = ""
      $0.confirm = ""
    }
    await store.send(.backToLoginTapped)
    await store.receive(\.delegate.passwordReset, "alice@example.com")
  }

  @Test(arguments: [AuthError.invalidCode, .codeExpired, .weakPassword, .network])
  func resetFailuresAreShown(_ error: AuthError) async {
    let store = TestStore(initialState: readyToReset) {
      ForgotPassword()
    } withDependencies: {
      $0.authClient.resetPassword = { _, _, _ in throw error }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.resetResponse, error) {
      $0.isLoading = false
      $0.error = error
    }
  }

  @Test func validation() {
    #expect(readyToReset.canSubmit)
    var shortCode = readyToReset
    shortCode.code = "65432"
    #expect(!shortCode.canSubmit)
    var weak = readyToReset
    weak.password = "weak"
    weak.confirm = "weak"
    #expect(weak.issues == [.passwordTooShort, .passwordMissingDigit])
    #expect(!weak.canSubmit)
    var mismatch = readyToReset
    mismatch.confirm = "Other1234"
    #expect(mismatch.issues == [.confirmMismatch])
  }

  @Test func revealTogglesKeepTheErrorAndResetOnSuccess() async {
    var state = readyToReset
    state.error = .invalidCode
    let store = TestStore(initialState: state) {
      ForgotPassword()
    } withDependencies: {
      $0.authClient.resetPassword = { _, _, _ in }
    }
    await store.send(\.binding.showPassword, true) { $0.showPassword = true }
    await store.send(\.binding.showConfirm, true) { $0.showConfirm = true }
    await store.send(.submitTapped) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.resetResponse, nil) {
      $0.isLoading = false
      $0.step = .done
      $0.code = ""
      $0.password = ""
      $0.confirm = ""
      $0.showPassword = false
      $0.showConfirm = false
    }
  }

  @Test func backDismisses() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: ForgotPassword.State()) {
      ForgotPassword()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    await store.send(.backTapped)
    #expect(dismissed.value)
  }

  @Test func issuesAreSplitByField() {
    var state = readyToReset
    state.password = "weak"
    state.confirm = "other"
    #expect(state.passwordFieldIssues == [.passwordTooShort, .passwordMissingDigit])
    #expect(state.confirmFieldIssues == [.confirmMismatch])
  }

  @Test func agentPaths() {
    #expect(ForgotPassword.activeScreen(ForgotPassword.State()).path == "auth/forgot/email")
    #expect(
      ForgotPassword.activeScreen(readyToReset).commands.map(\.name) == [
        "code", "password", "confirm", "show-password", "show-confirm", "submit",
      ]
    )
    #expect(ForgotPassword.activeScreen(readyToReset).summary.contains(SummaryItem("revealed", "none")))
    #expect(ForgotPassword.activeScreen(ForgotPassword.State(step: .done)).commands.map(\.name) == ["to-login"])
  }
}
