import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct LoginTests {
  let alice = MockAccounts.session(named: "alice")!

  @Test func canSubmitNeedsAValidEmailAndAPassword() {
    #expect(!Login.State().canSubmit)
    #expect(!Login.State(email: "alice@example", password: "x").canSubmit)
    #expect(!Login.State(email: "alice@example.com").canSubmit)
    #expect(Login.State(email: "alice@example.com", password: "x").canSubmit)
    #expect(!Login.State(email: "alice@example.com", password: "x", isLoading: true).canSubmit)
    #expect(!Login.State(email: "alice@example.com", password: "x", isGoogleLoading: true).canSubmit)
  }

  @Test func happyPath() async {
    let alice = alice
    let store = TestStore(initialState: Login.State(email: "alice@example.com", password: "Passw0rd!")) {
      Login()
    } withDependencies: {
      $0.authClient.login = { email, password in
        guard email == "alice@example.com", password == "Passw0rd!" else { throw AuthError.invalidCredentials }
        return alice
      }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.loginResponse.success) { $0.isLoading = false }
    await store.receive(\.delegate.authenticated, alice)
  }

  @Test func googleSignIn() async {
    let becca = MockAccounts.session(for: MockAccounts.google.user)
    let store = TestStore(initialState: Login.State(error: .invalidCredentials)) {
      Login()
    } withDependencies: {
      $0.authClient.signInWithGoogle = { becca }
    }
    await store.send(.googleTapped) {
      $0.isGoogleLoading = true
      $0.error = nil
    }
    await store.receive(\.loginResponse.success) { $0.isGoogleLoading = false }
    await store.receive(\.delegate.authenticated, becca)
  }

  @Test func googleFailureIsShown() async {
    let store = TestStore(initialState: Login.State()) {
      Login()
    } withDependencies: {
      $0.authClient.signInWithGoogle = { throw AuthError.network }
    }
    await store.send(.googleTapped) { $0.isGoogleLoading = true }
    await store.receive(\.loginResponse.failure, .network) {
      $0.isGoogleLoading = false
      $0.error = .network
    }
  }

  @Test func googleIsIgnoredWhileASignInIsInFlight() async {
    let store = TestStore(initialState: Login.State(isLoading: true)) { Login() }
    await store.send(.googleTapped)
  }

  /// An account that registered but never verified its email goes to verification instead of an error.
  @Test func unverifiedAccountGoesToVerification() async {
    let store = TestStore(initialState: Login.State(email: "carol@example.com", password: "Secret123")) {
      Login()
    } withDependencies: {
      $0.authClient.login = { _, _ in throw AuthError.emailNotVerified }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.loginResponse.failure, .emailNotVerified) { $0.isLoading = false }
    await store.receive(\.delegate.verifyEmail, "carol@example.com")
  }

  @Test func togglesKeepTheError() async {
    let store = TestStore(initialState: Login.State(error: .invalidCredentials)) { Login() }
    await store.send(\.binding.showPassword, true) { $0.showPassword = true }
    await store.send(\.binding.keepSignedIn, false) { $0.keepSignedIn = false }
  }

  @Test(arguments: [AuthError.invalidCredentials, .accountLocked, .network])
  func failuresAreShown(_ error: AuthError) async {
    let store = TestStore(initialState: Login.State(email: "alice@example.com", password: "nope")) {
      Login()
    } withDependencies: {
      $0.authClient.login = { _, _ in throw error }
    }
    await store.send(.submitTapped) { $0.isLoading = true }
    await store.receive(\.loginResponse.failure, error) {
      $0.isLoading = false
      $0.error = error
    }
  }

  @Test func editingClearsTheError() async {
    let store = TestStore(initialState: Login.State(email: "alice@example.com", password: "x", error: .invalidCredentials)) {
      Login()
    }
    await store.send(\.binding.password, "y") {
      $0.password = "y"
      $0.error = nil
    }
  }

  @Test func submitIsIgnoredWhenInvalid() async {
    let store = TestStore(initialState: Login.State(email: "not-an-email", password: "x")) { Login() }
    await store.send(.submitTapped)
  }

  @Test func navigationDelegatesCarryTheEmail() async {
    let store = TestStore(initialState: Login.State(email: "alice@example.com")) { Login() }
    await store.send(.useOTPTapped)
    await store.receive(\.delegate.useOTP, "alice@example.com")
    await store.send(.registerTapped)
    await store.receive(\.delegate.register)
    await store.send(.forgotPasswordTapped)
    await store.receive(\.delegate.forgotPassword, "alice@example.com")
  }

  @Test func agentCommands() throws {
    let screen = Login.activeScreen(Login.State(email: "alice@example.com"))
    #expect(screen.path == "auth/login")
    #expect(
      screen.commands.map(\.name) == [
        "email", "password", "show-password", "keep-signed-in", "submit", "google", "use-otp", "register", "forgot",
      ]
    )
    #expect(screen.command(named: "submit")?.disabledReason == "canSubmit=false")
    #expect(screen.command(named: "google")?.disabledReason == nil)
    #expect(screen.summary.map(\.key) == Login.summaryKeys)
    #expect(screen.summary.contains(SummaryItem("keepSignedIn", true)))
    #expect(screen.summary.contains(SummaryItem("revealed", "none")))
    let revealed = Login.activeScreen(Login.State(showPassword: true, isGoogleLoading: true))
    #expect(revealed.summary.contains(SummaryItem("revealed", "password")))
    #expect(revealed.summary.contains(SummaryItem("loading", true)))
    #expect(revealed.command(named: "google")?.disabledReason == "loading=true")
    let withError = Login.activeScreen(Login.State(error: .accountLocked))
    #expect(withError.errorCode == "accountLocked")
  }
}
