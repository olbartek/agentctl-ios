import AgentCtlCore
import AuthClient
import AuthFeature
import ComposableArchitecture
import Models
import Testing

@MainActor
@Suite(.serialized)
struct AuthFlowTests {
  let alice = MockAccounts.session(named: "alice")!

  @Test func loginLinksPushScreens() async {
    let store = TestStore(initialState: AuthFlow.State(login: Login.State(email: "alice@example.com"))) {
      AuthFlow()
    }
    await store.send(.login(.useOTPTapped))
    await store.receive(\.login.delegate.useOTP) {
      $0.path[id: 0] = .otpLogin(OTPLogin.State(email: "alice@example.com"))
    }
    await store.send(.path(.popFrom(id: 0))) { $0.path = StackState() }
    await store.send(.login(.registerTapped))
    await store.receive(\.login.delegate.register) {
      $0.path[id: 1] = .register(Register.State())
    }
    await store.send(.path(.popFrom(id: 1))) { $0.path = StackState() }
    await store.send(.login(.forgotPasswordTapped))
    await store.receive(\.login.delegate.forgotPassword) {
      $0.path[id: 2] = .forgotPassword(ForgotPassword.State(email: "alice@example.com"))
    }
  }

  @Test func authenticationFromLoginIsForwardedWithKeepSignedIn() async {
    let store = TestStore(initialState: AuthFlow.State()) { AuthFlow() }
    await store.send(.login(.delegate(.authenticated(alice))))
    await store.receive(\.delegate, .authenticated(alice, remember: true))
    await store.send(.login(.binding(.set(\.keepSignedIn, false)))) { $0.login.keepSignedIn = false }
    await store.send(.login(.delegate(.authenticated(alice))))
    await store.receive(\.delegate, .authenticated(alice, remember: false))
  }

  /// OTP login, Google sign-up and email verification all use Login's "Keep me signed in".
  @Test func authenticationFromPushedScreensIsForwarded() async {
    let store = TestStore(
      initialState: AuthFlow.State(
        login: Login.State(keepSignedIn: false),
        path: StackState([
          .otpLogin(OTPLogin.State()), .register(Register.State()),
          .verifyEmail(VerifyEmail.State(email: "alice@example.com")),
        ])
      )
    ) {
      AuthFlow()
    }
    await store.send(.path(.element(id: 0, action: .otpLogin(.delegate(.authenticated(alice))))))
    await store.receive(\.delegate, .authenticated(alice, remember: false))
    await store.send(.path(.element(id: 1, action: .register(.delegate(.authenticated(alice))))))
    await store.receive(\.delegate, .authenticated(alice, remember: false))
    await store.send(.path(.element(id: 2, action: .verifyEmail(.delegate(.authenticated(alice))))))
    await store.receive(\.delegate, .authenticated(alice, remember: false))
  }

  @Test func registrationPushesVerificationWithACooldown() async {
    let store = TestStore(initialState: AuthFlow.State(path: StackState([.register(Register.State())]))) {
      AuthFlow()
    }
    await store.send(.path(.element(id: 0, action: .register(.delegate(.verifyEmail(email: "carol@example.com")))))) {
      $0.path[id: 1] = .verifyEmail(VerifyEmail.State(email: "carol@example.com", resendIn: 30))
    }
  }

  @Test func unverifiedLoginPushesVerificationWithoutACooldown() async {
    let store = TestStore(initialState: AuthFlow.State()) { AuthFlow() }
    await store.send(.login(.delegate(.verifyEmail(email: "carol@example.com")))) {
      $0.path[id: 0] = .verifyEmail(VerifyEmail.State(email: "carol@example.com", resendIn: 0))
    }
  }

  /// The screens' own back buttons pop through `dismiss`, like the agent's `back`.
  @Test func backButtonsPopTheStack() async {
    let store = TestStore(
      initialState: AuthFlow.State(
        path: StackState([.register(Register.State()), .verifyEmail(VerifyEmail.State(email: "c@example.com", resendIn: 0))])
      )
    ) {
      AuthFlow()
    }
    await store.send(.path(.element(id: 1, action: .verifyEmail(.backTapped))))
    await store.receive(\.path.popFrom) { $0.path.pop(from: 1) }
    await store.send(.path(.element(id: 0, action: .register(.backTapped))))
    await store.receive(\.path.popFrom) { $0.path = StackState() }
  }

  @Test func passwordResetPopsToLoginWithTheEmail() async {
    let store = TestStore(
      initialState: AuthFlow.State(
        login: Login.State(email: "old@example.com", password: "typed", error: .invalidCredentials),
        path: StackState([.forgotPassword(ForgotPassword.State(step: .done, email: "alice@example.com"))])
      )
    ) {
      AuthFlow()
    }
    await store.send(.path(.element(id: 0, action: .forgotPassword(.backToLoginTapped))))
    await store.receive(\.path[id: 0].forgotPassword.delegate.passwordReset) {
      $0.path = StackState()
      $0.login = Login.State(email: "alice@example.com")
    }
  }

  @Test func poppingOTPCancelsItsCountdown() async {
    let clock = TestClock()
    let store = TestStore(initialState: AuthFlow.State(path: StackState([.otpLogin(OTPLogin.State(email: "alice@example.com"))]))) {
      AuthFlow()
    } withDependencies: {
      $0.authClient.sendOTP = { _ in }
      $0.continuousClock = clock
    }
    await store.send(.path(.element(id: 0, action: .otpLogin(.sendTapped)))) {
      $0.path[id: 0, case: \.otpLogin]?.isLoading = true
    }
    await store.receive(\.path[id: 0].otpLogin.sendResponse) {
      $0.path[id: 0, case: \.otpLogin]?.isLoading = false
      $0.path[id: 0, case: \.otpLogin]?.step = .code
      $0.path[id: 0, case: \.otpLogin]?.resendIn = 30
    }
    await store.send(.path(.popFrom(id: 0))) { $0.path = StackState() }
    await clock.advance(by: .seconds(30))
  }

  @Test func agentScreenLiftsPushedCommandsAndAddsBack() throws {
    var state = AuthFlow.State()
    let root = AuthFlow.activeScreen(state)
    #expect(root.path == "auth/login")
    #expect(root.command(named: "back") == nil)
    #expect(try root.command(named: "email")?.makeAction("a@b.co") != nil)

    state.path.append(.otpLogin(OTPLogin.State(email: "alice@example.com")))
    let id = try #require(state.path.ids.last)
    let pushed = AuthFlow.activeScreen(state)
    #expect(pushed.path == "auth/otp/email")
    #expect(pushed.commands.map(\.name) == ["email", "send", "back"])
    #expect(pushed.identity == "\(id.debugDescription)/auth/otp/email")
  }

  @Test func registryListsEveryAuthPath() {
    let paths = AuthFlow.registry.map(\.path)
    #expect(
      paths == [
        "auth/login", "auth/otp/email", "auth/otp/code", "auth/register", "auth/register/verify", "auth/forgot/email",
        "auth/forgot/reset", "auth/forgot/done",
      ]
    )
    #expect(AuthFlow.registry.first?.commands.contains { $0.name == "back" } == false)
    #expect(AuthFlow.registry.last?.commands.last?.name == "back")
  }
}
