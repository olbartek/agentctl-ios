import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct RegisterTests {
  let valid = Register.State(
    name: "Carol",
    email: "carol@example.com",
    password: "Secret123",
    confirm: "Secret123",
    acceptedTerms: true
  )

  @Test func validation() {
    #expect(Register.State().issues == [])
    #expect(Register.State(email: "carol@").issues == [.email])
    #expect(Register.State(password: "short").issues == [.passwordTooShort, .passwordMissingDigit])
    #expect(Register.State(password: "Secret123", confirm: "Secret12").issues == [.confirmMismatch])
    #expect(valid.issues == [])
    #expect(valid.canSubmit)
    var noTerms = valid
    noTerms.acceptedTerms = false
    #expect(!noTerms.canSubmit)
    var noName = valid
    noName.name = "  "
    #expect(!noName.canSubmit)
    var mismatch = valid
    mismatch.confirm = "Secret124"
    #expect(!mismatch.canSubmit)
    var busy = valid
    busy.isGoogleLoading = true
    #expect(!busy.canSubmit)
  }

  @Test func issuesAreSplitByField() {
    let state = Register.State(email: "carol@", password: "short", confirm: "other")
    #expect(state.emailFieldIssues == [.email])
    #expect(state.passwordFieldIssues == [.passwordTooShort, .passwordMissingDigit])
    #expect(state.confirmFieldIssues == [.confirmMismatch])
  }

  /// Registering emails a code; the next step is email verification.
  @Test func happyPathGoesToVerification() async {
    let store = TestStore(initialState: valid) {
      Register()
    } withDependencies: {
      $0.authClient.register = { name, email, password in
        guard name == "Carol", email == "carol@example.com", password == "Secret123" else {
          throw AuthError.network
        }
      }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.registerResponse, nil) { $0.isLoading = false }
    await store.receive(\.delegate.verifyEmail, "carol@example.com")
  }

  @Test func googleSignUp() async {
    let becca = MockAccounts.session(for: MockAccounts.google.user)
    let store = TestStore(initialState: Register.State()) {
      Register()
    } withDependencies: {
      $0.authClient.signInWithGoogle = { becca }
    }
    await store.send(.googleTapped) { $0.isGoogleLoading = true }
    await store.receive(\.googleResponse.success) { $0.isGoogleLoading = false }
    await store.receive(\.delegate.authenticated, becca)
  }

  @Test func googleFailureIsShown() async {
    let store = TestStore(initialState: Register.State()) {
      Register()
    } withDependencies: {
      $0.authClient.signInWithGoogle = { throw AuthError.network }
    }
    await store.send(.googleTapped) { $0.isGoogleLoading = true }
    await store.receive(\.googleResponse.failure, .network) {
      $0.isGoogleLoading = false
      $0.error = .network
    }
  }

  @Test func backDismisses() async {
    let dismissed = LockIsolated(0)
    let store = TestStore(initialState: Register.State()) {
      Register()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.withValue { $0 += 1 } }
    }
    await store.send(.backTapped)
    #expect(dismissed.value == 1)
  }

  @Test func revealTogglesKeepTheError() async {
    let store = TestStore(initialState: Register.State(error: .emailTaken)) { Register() }
    await store.send(\.binding.showPassword, true) { $0.showPassword = true }
    await store.send(\.binding.showConfirm, true) { $0.showConfirm = true }
  }

  @Test(arguments: [AuthError.emailTaken, .weakPassword, .network])
  func failuresAreShown(_ error: AuthError) async {
    let store = TestStore(initialState: valid) {
      Register()
    } withDependencies: {
      $0.authClient.register = { _, _, _ in throw error }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.registerResponse, error) {
      $0.isLoading = false
      $0.error = error
    }
    await store.send(\.binding.email, "carol2@example.com") {
      $0.email = "carol2@example.com"
      $0.error = nil
    }
  }

  @Test func submitIsIgnoredWhenInvalid() async {
    let store = TestStore(initialState: Register.State(email: "carol@example.com")) { Register() }
    await store.send(.submitTapped)
  }

  @Test func agentCommands() throws {
    let screen = Register.activeScreen(Register.State(email: "carol@", password: "short"))
    #expect(screen.summary.first { $0.key == "issues" }?.value == "email,passwordTooShort,passwordMissingDigit")
    #expect(try screen.command(named: "terms")?.makeAction("on") != nil)
    #expect(throws: AgentCommandError.invalidArgument("expected on|off")) {
      try screen.command(named: "terms")?.makeAction("yes")
    }
    #expect(
      screen.commands.map(\.name) == [
        "name", "email", "password", "confirm", "show-password", "show-confirm", "terms", "submit", "google",
      ]
    )
    #expect(screen.summary.map(\.key) == Register.summaryKeys)
    let revealed = Register.activeScreen(Register.State(showPassword: true, showConfirm: true))
    #expect(revealed.summary.contains(SummaryItem("revealed", "password,confirm")))
  }
}
