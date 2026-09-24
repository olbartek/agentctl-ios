import AuthClient
import ComposableArchitecture
import Models
import Testing

struct AuthBackendLoginTests {
  let backend = AuthBackend(clock: TestClock())

  @Test func seededAccountsLogIn() async throws {
    let alice = try await backend.login(email: "alice@example.com", password: "Passw0rd!")
    #expect(alice.user.name == "Alice")
    #expect(alice == MockAccounts.session(named: "alice"))
    let bob = try await backend.login(email: " Bob@Example.com ", password: "Hunter22x")
    #expect(bob.user.email == "bob@example.com")
  }

  @Test func wrongPasswordAndUnknownEmail() async {
    await #expect(throws: AuthError.invalidCredentials) {
      try await backend.login(email: "alice@example.com", password: "nope")
    }
    await #expect(throws: AuthError.invalidCredentials) {
      try await backend.login(email: "nobody@example.com", password: "Passw0rd!")
    }
  }

  @Test func fifthFailureLocksTheAccount() async throws {
    for _ in 1...4 {
      await #expect(throws: AuthError.invalidCredentials) {
        try await backend.login(email: "alice@example.com", password: "nope")
      }
    }
    await #expect(throws: AuthError.accountLocked) {
      try await backend.login(email: "alice@example.com", password: "nope")
    }
    await #expect(throws: AuthError.accountLocked) {
      try await backend.login(email: "alice@example.com", password: "Passw0rd!")
    }
    // Other accounts are unaffected.
    _ = try await backend.login(email: "bob@example.com", password: "Hunter22x")
  }

  @Test func successResetsTheFailureCount() async throws {
    for _ in 1...4 {
      _ = try? await backend.login(email: "alice@example.com", password: "nope")
    }
    _ = try await backend.login(email: "alice@example.com", password: "Passw0rd!")
    await #expect(throws: AuthError.invalidCredentials) {
      try await backend.login(email: "alice@example.com", password: "nope")
    }
  }

  @Test func lockedAccountIsAlwaysLocked() async {
    await #expect(throws: AuthError.accountLocked) {
      try await backend.login(email: "locked@example.com", password: "anything")
    }
  }
}

struct AuthBackendOTPTests {
  let clock = TestClock()
  var backend: AuthBackend { AuthBackend(clock: clock) }

  @Test func sendAndVerify() async throws {
    let backend = backend
    try await backend.sendOTP(email: "alice@example.com")
    let session = try await backend.verifyOTP(email: "alice@example.com", code: "123456")
    #expect(session.user.name == "Alice")
    // The code is single use.
    await #expect(throws: AuthError.invalidCode) {
      try await backend.verifyOTP(email: "alice@example.com", code: "123456")
    }
  }

  @Test func unknownEmail() async {
    await #expect(throws: AuthError.unknownEmail) { try await backend.sendOTP(email: "nobody@example.com") }
  }

  @Test func resendCooldown() async throws {
    let backend = backend
    try await backend.sendOTP(email: "alice@example.com")
    await clock.advance(by: .seconds(29))
    await #expect(throws: AuthError.resendNotAvailable) { try await backend.sendOTP(email: "alice@example.com") }
    await clock.advance(by: .seconds(1))
    try await backend.sendOTP(email: "alice@example.com")
  }

  @Test func threeWrongCodesRequireAResend() async throws {
    let backend = backend
    try await backend.sendOTP(email: "alice@example.com")
    for _ in 1...3 {
      await #expect(throws: AuthError.invalidCode) {
        try await backend.verifyOTP(email: "alice@example.com", code: "000000")
      }
    }
    await #expect(throws: AuthError.invalidCode) {
      try await backend.verifyOTP(email: "alice@example.com", code: "123456")
    }
    await clock.advance(by: .seconds(30))
    try await backend.sendOTP(email: "alice@example.com")
    _ = try await backend.verifyOTP(email: "alice@example.com", code: "123456")
  }

  @Test func codesExpireAfterFiveMinutes() async throws {
    let backend = backend
    try await backend.sendOTP(email: "alice@example.com")
    await clock.advance(by: .seconds(299))
    await #expect(throws: AuthError.invalidCode) {
      try await backend.verifyOTP(email: "alice@example.com", code: "000000")
    }
    await clock.advance(by: .seconds(1))
    await #expect(throws: AuthError.codeExpired) {
      try await backend.verifyOTP(email: "alice@example.com", code: "123456")
    }
  }

  @Test func verifyWithoutSending() async {
    await #expect(throws: AuthError.invalidCode) {
      try await backend.verifyOTP(email: "alice@example.com", code: "123456")
    }
  }
}

struct AuthBackendRegisterAndResetTests {
  let clock = TestClock()

  @Test func registerVerifyThenLogIn() async throws {
    let backend = AuthBackend(clock: clock)
    try await backend.register(name: "Carol", email: "Carol@Example.com", password: "Secret123")
    await #expect(throws: AuthError.emailNotVerified) {
      try await backend.login(email: "carol@example.com", password: "Secret123")
    }
    await #expect(throws: AuthError.invalidCode) {
      try await backend.verifyEmail(email: "carol@example.com", code: "000000")
    }
    let session = try await backend.verifyEmail(email: "carol@example.com", code: "123456")
    #expect(session.user == User(id: "u5", name: "Carol", email: "carol@example.com"))
    let again = try await backend.login(email: "carol@example.com", password: "Secret123")
    #expect(again == session)
  }

  @Test func registerErrors() async {
    let backend = AuthBackend(clock: clock)
    await #expect(throws: AuthError.emailTaken) {
      try await backend.register(name: "A", email: "alice@example.com", password: "Secret123")
    }
    await #expect(throws: AuthError.weakPassword) {
      try await backend.register(name: "C", email: "carol@example.com", password: "short")
    }
  }

  @Test func verificationCodesExpireAndResendHasACooldown() async throws {
    let backend = AuthBackend(clock: clock)
    try await backend.register(name: "Carol", email: "carol@example.com", password: "Secret123")
    await #expect(throws: AuthError.resendNotAvailable) { try await backend.resendVerification(email: "carol@example.com") }
    await clock.advance(by: .seconds(300))
    await #expect(throws: AuthError.codeExpired) {
      try await backend.verifyEmail(email: "carol@example.com", code: "123456")
    }
    try await backend.resendVerification(email: "carol@example.com")
    _ = try await backend.verifyEmail(email: "carol@example.com", code: "123456")
    await #expect(throws: AuthError.invalidCode) { try await backend.resendVerification(email: "carol@example.com") }
  }

  @Test func unverifiedAccountsCannotUseOneTimeCodes() async throws {
    let backend = AuthBackend(clock: clock)
    try await backend.register(name: "Carol", email: "carol@example.com", password: "Secret123")
    await #expect(throws: AuthError.emailNotVerified) { try await backend.sendOTP(email: "carol@example.com") }
  }

  @Test func googleSignInIsTheGoogleTestAccount() async throws {
    let backend = AuthBackend(clock: clock)
    let session = await backend.signInWithGoogle()
    #expect(session.user == MockAccounts.google.user)
    #expect(await backend.signInWithGoogle() == session)
    await #expect(throws: AuthError.invalidCredentials) {
      try await backend.login(email: "becca@gmail.com", password: "anything1")
    }
  }

  @Test func resetFlow() async throws {
    let backend = AuthBackend(clock: clock)
    await backend.requestPasswordReset(email: "alice@example.com")
    await #expect(throws: AuthError.invalidCode) {
      try await backend.resetPassword(email: "alice@example.com", code: "000000", newPassword: "NewPass123")
    }
    await #expect(throws: AuthError.weakPassword) {
      try await backend.resetPassword(email: "alice@example.com", code: "654321", newPassword: "weak")
    }
    try await backend.resetPassword(email: "alice@example.com", code: "654321", newPassword: "NewPass123")
    _ = try await backend.login(email: "alice@example.com", password: "NewPass123")
    await #expect(throws: AuthError.invalidCredentials) {
      try await backend.login(email: "alice@example.com", password: "Passw0rd!")
    }
  }

  @Test func resetUnlocksALockedAccount() async throws {
    let backend = AuthBackend(clock: clock)
    for _ in 1...5 {
      _ = try? await backend.login(email: "alice@example.com", password: "nope")
    }
    await backend.requestPasswordReset(email: "alice@example.com")
    try await backend.resetPassword(email: "alice@example.com", code: "654321", newPassword: "NewPass123")
    _ = try await backend.login(email: "alice@example.com", password: "NewPass123")
  }

  @Test func unknownEmailRequestSucceedsButIssuesNoCode() async {
    let backend = AuthBackend(clock: clock)
    await backend.requestPasswordReset(email: "nobody@example.com")
    await #expect(throws: AuthError.invalidCode) {
      try await backend.resetPassword(email: "nobody@example.com", code: "654321", newPassword: "NewPass123")
    }
  }

  @Test func resetCodesExpire() async {
    let backend = AuthBackend(clock: clock)
    await backend.requestPasswordReset(email: "alice@example.com")
    await clock.advance(by: .seconds(300))
    await #expect(throws: AuthError.codeExpired) {
      try await backend.resetPassword(email: "alice@example.com", code: "654321", newPassword: "NewPass123")
    }
  }
}
