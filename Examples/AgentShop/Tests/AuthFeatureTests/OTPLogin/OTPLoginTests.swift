import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct OTPLoginTests {
  let alice = MockAccounts.session(named: "alice")!

  /// Send, blocked resend, the full 30 s countdown, a real resend, then a successful verify (which cancels
  /// the countdown).
  @Test func sendCountdownResendAndVerify() async {
    let clock = TestClock()
    let alice = alice
    let store = TestStore(initialState: OTPLogin.State(email: "alice@example.com")) {
      OTPLogin()
    } withDependencies: {
      $0.authClient.sendOTP = { _ in }
      $0.authClient.verifyOTP = { _, code in
        guard code == "123456" else { throw AuthError.invalidCode }
        return alice
      }
      $0.continuousClock = clock
    }

    await store.send(.sendTapped) { $0.isLoading = true }
    await store.receive(\.sendResponse, nil) {
      $0.isLoading = false
      $0.step = .code
      $0.resendIn = 30
    }

    await store.send(.resendTapped) { $0.error = .resendNotAvailable }

    await clock.advance(by: .seconds(30))
    for remaining in (0..<30).reversed() {
      await store.receive(\.tick) { $0.resendIn = remaining }
    }

    await store.send(.resendTapped) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.sendResponse, nil) {
      $0.isLoading = false
      $0.resendIn = 30
    }

    await store.send(\.binding.code, "12-34 56") { $0.code = "123456" }
    await store.send(.verifyTapped) { $0.isLoading = true }
    await store.receive(\.verifyResponse.success) { $0.isLoading = false }
    await store.receive(\.delegate.authenticated, alice)
  }

  @Test(arguments: [AuthError.unknownEmail, .network])
  func sendFailures(_ error: AuthError) async {
    let store = TestStore(initialState: OTPLogin.State(email: "nobody@example.com")) {
      OTPLogin()
    } withDependencies: {
      $0.authClient.sendOTP = { _ in throw error }
    }
    await store.send(.sendTapped) { $0.isLoading = true }
    await store.receive(\.sendResponse, error) {
      $0.isLoading = false
      $0.error = error
    }
  }

  @Test func threeWrongCodesRequireAResend() async {
    let store = TestStore(initialState: OTPLogin.State(step: .code, email: "alice@example.com")) {
      OTPLogin()
    } withDependencies: {
      $0.authClient.verifyOTP = { _, _ in throw AuthError.invalidCode }
    }
    for attemptsLeft in [2, 1, 0] {
      await store.send(\.binding.code, "000000") {
        $0.code = "000000"
        $0.error = nil
      }
      await store.send(.verifyTapped) { $0.isLoading = true }
      await store.receive(\.verifyResponse.failure, .invalidCode) {
        $0.isLoading = false
        $0.error = .invalidCode
        $0.attemptsLeft = attemptsLeft
        $0.code = ""
      }
    }
    await store.send(\.binding.code, "123456") {
      $0.code = "123456"
      $0.error = nil
    }
    #expect(!store.state.canVerify)
    await store.send(.verifyTapped)
  }

  @Test(arguments: [AuthError.codeExpired, .network])
  func verifyFailuresKeepTheAttempts(_ error: AuthError) async {
    let store = TestStore(initialState: OTPLogin.State(step: .code, email: "alice@example.com", code: "123456")) {
      OTPLogin()
    } withDependencies: {
      $0.authClient.verifyOTP = { _, _ in throw error }
    }
    await store.send(.verifyTapped) { $0.isLoading = true }
    await store.receive(\.verifyResponse.failure, error) {
      $0.isLoading = false
      $0.error = error
    }
  }

  @Test func codeIsDigitsOnlyAndAtMostSix() async {
    let store = TestStore(initialState: OTPLogin.State(step: .code)) { OTPLogin() }
    await store.send(\.binding.code, "12a345678") { $0.code = "123456" }
  }

  @Test func backDismisses() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: OTPLogin.State(step: .code, email: "alice@example.com")) {
      OTPLogin()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    await store.send(.backTapped)
    #expect(dismissed.value)
  }

  @Test func agentPathsAndCommands() {
    let email = OTPLogin.activeScreen(OTPLogin.State())
    #expect(email.path == "auth/otp/email")
    #expect(email.commands.map(\.name) == ["email", "send"])
    let code = OTPLogin.activeScreen(OTPLogin.State(step: .code, resendIn: 12))
    #expect(code.path == "auth/otp/code")
    #expect(code.commands.map(\.name) == ["code", "verify", "resend"])
    #expect(code.command(named: "resend")?.disabledReason == nil)
    #expect(code.summary.contains(SummaryItem("resendIn", 12)))
  }
}
