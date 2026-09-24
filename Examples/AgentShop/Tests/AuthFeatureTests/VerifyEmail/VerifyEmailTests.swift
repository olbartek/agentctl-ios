import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct VerifyEmailTests {
  let carol = Session(user: User(id: "u5", name: "Carol", email: "carol@example.com"), token: "mock-token-u5")

  /// The countdown starts on appear (registration just sent a code), a resend during it is refused, a real resend
  /// restarts it, and a successful verify cancels it.
  @Test func countdownResendAndVerify() async {
    let clock = TestClock()
    let carol = carol
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com")) {
      VerifyEmail()
    } withDependencies: {
      $0.authClient.resendVerification = { _ in }
      $0.authClient.verifyEmail = { email, code in
        guard email == "carol@example.com", code == "123456" else { throw AuthError.invalidCode }
        return carol
      }
      $0.continuousClock = clock
    }

    await store.send(.onAppear)
    await store.send(.resendTapped) { $0.error = .resendNotAvailable }

    await clock.advance(by: .seconds(30))
    for remaining in (0..<30).reversed() {
      await store.receive(\.tick) { $0.resendIn = remaining }
    }

    await store.send(.resendTapped) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.resendResponse, nil) {
      $0.isLoading = false
      $0.resendIn = 30
    }

    await store.send(\.binding.code, "12 34-56") { $0.code = "123456" }
    await store.send(.verifyTapped) { $0.isLoading = true }
    await store.receive(\.verifyResponse.success) { $0.isLoading = false }
    await store.receive(\.delegate.authenticated, carol)
  }

  /// Opened from login for an unverified account: nothing to count down, so resend works at once.
  @Test func noCountdownWhenResendIsAvailable() async {
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com", resendIn: 0)) {
      VerifyEmail()
    } withDependencies: {
      $0.authClient.resendVerification = { _ in throw AuthError.resendNotAvailable }
    }
    await store.send(.onAppear)
    await store.send(.resendTapped) { $0.isLoading = true }
    await store.receive(\.resendResponse, .resendNotAvailable) {
      $0.isLoading = false
      $0.error = .resendNotAvailable
    }
  }

  @Test func wrongCodeClearsTheCode() async {
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com", code: "000000", resendIn: 0)) {
      VerifyEmail()
    } withDependencies: {
      $0.authClient.verifyEmail = { _, _ in throw AuthError.invalidCode }
    }
    await store.send(.verifyTapped) { $0.isLoading = true }
    await store.receive(\.verifyResponse.failure, .invalidCode) {
      $0.isLoading = false
      $0.error = .invalidCode
      $0.code = ""
    }
    #expect(!store.state.canVerify)
    await store.send(.verifyTapped)
  }

  @Test(arguments: [AuthError.codeExpired, .network])
  func otherFailuresKeepTheCode(_ error: AuthError) async {
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com", code: "123456", resendIn: 0)) {
      VerifyEmail()
    } withDependencies: {
      $0.authClient.verifyEmail = { _, _ in throw error }
    }
    await store.send(.verifyTapped) { $0.isLoading = true }
    await store.receive(\.verifyResponse.failure, error) {
      $0.isLoading = false
      $0.error = error
    }
  }

  @Test func codeIsDigitsOnlyAndAtMostSix() async {
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com", error: .invalidCode)) {
      VerifyEmail()
    }
    await store.send(\.binding.code, "12a345678") {
      $0.code = "123456"
      $0.error = nil
    }
  }

  @Test func backDismisses() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: VerifyEmail.State(email: "carol@example.com")) {
      VerifyEmail()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    await store.send(.backTapped)
    #expect(dismissed.value)
  }

  @Test func agentScreen() {
    let screen = VerifyEmail.activeScreen(VerifyEmail.State(email: "carol@example.com", code: "123"))
    #expect(screen.path == "auth/register/verify")
    #expect(screen.commands.map(\.name) == ["code", "verify", "resend"])
    #expect(screen.command(named: "verify")?.disabledReason == "canVerify=false")
    #expect(screen.command(named: "resend")?.disabledReason == nil)
    #expect(screen.summary.map(\.key) == VerifyEmail.summaryKeys)
    #expect(screen.summary.contains(SummaryItem("resendIn", 30)))
    #expect(screen.appearAction != nil)
  }
}
