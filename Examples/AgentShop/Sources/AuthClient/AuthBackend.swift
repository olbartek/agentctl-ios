import ComposableArchitecture
import Models

/// The in-memory auth server behind ``AuthClient``'s `liveValue`.
///
/// Rules (spec §4.1 and plan M4):
/// - Login: an unknown email or wrong password gives `invalidCredentials`. The 5th consecutive failure on an
///   account gives `accountLocked`, and the account stays locked until a password reset. `locked@example.com`
///   is always locked.
/// - OTP: `sendOTP` for an unknown email gives `unknownEmail`; a second send within 30 s gives `resendNotAvailable`.
///   A code expires 5 minutes after sending (`codeExpired`). After 3 wrong codes every verify fails with
///   `invalidCode` until a resend.
/// - Register: `emailTaken` for an existing account, `weakPassword` below the password rules. A new account is
///   unverified: a code is emailed, and until `verifyEmail` succeeds, logging in gives `emailNotVerified`.
///   Resending the code is blocked for 30 s; a code expires after 5 minutes.
/// - Google: `signInWithGoogle` always signs in as the Google test account (Becca Ade).
/// - Password reset: requesting always succeeds but only issues a code for known accounts. A wrong code gives
///   `invalidCode`, an old one `codeExpired`, a weak password `weakPassword`. A reset unlocks the account.
///
/// Times are measured on the injected clock, so `appctl`'s `advance 5m` expires codes.
public actor AuthBackend {
  public static let lockoutThreshold = 5
  public static let maxCodeAttempts = 3
  public static let resendCooldown = Duration.seconds(30)
  public static let codeLifetime = Duration.seconds(5 * 60)

  struct IssuedCode {
    var code: String
    var age: Stopwatch
    var failedAttempts = 0
  }

  private let clock: any Clock<Duration>
  private var accounts: [String: MockAccount]
  private var failedLogins: [String: Int] = [:]
  private var lockedEmails: Set<String> = []
  private var otpCodes: [String: IssuedCode] = [:]
  private var resetCodes: [String: IssuedCode] = [:]
  private var verificationCodes: [String: IssuedCode] = [:]
  private var nextUserNumber: Int

  public init(clock: any Clock<Duration>, accounts: [MockAccount] = MockAccounts.seed) {
    self.clock = clock
    self.accounts = Dictionary(accounts.map { ($0.user.email, $0) }, uniquingKeysWith: { first, _ in first })
    self.nextUserNumber = accounts.count + 1
  }

  public func login(email: String, password: String) throws(AuthError) -> Session {
    let email = normalized(email)
    guard let account = accounts[email] else { throw .invalidCredentials }
    if account.alwaysLocked || lockedEmails.contains(email) { throw .accountLocked }
    guard let expected = account.password, expected == password else {
      let failures = failedLogins[email, default: 0] + 1
      failedLogins[email] = failures
      if failures >= Self.lockoutThreshold {
        lockedEmails.insert(email)
        throw .accountLocked
      }
      throw .invalidCredentials
    }
    failedLogins[email] = nil
    guard account.isVerified else { throw .emailNotVerified }
    return MockAccounts.session(for: account.user)
  }

  public func sendOTP(email: String) throws(AuthError) {
    let email = normalized(email)
    guard let account = accounts[email] else { throw .unknownEmail }
    guard account.isVerified else { throw .emailNotVerified }
    if let issued = otpCodes[email], issued.age.elapsed() < Self.resendCooldown {
      throw .resendNotAvailable
    }
    otpCodes[email] = IssuedCode(code: MockAccounts.otpCode, age: clock.stopwatch())
  }

  public func verifyOTP(email: String, code: String) throws(AuthError) -> Session {
    let email = normalized(email)
    guard var issued = otpCodes[email], let account = accounts[email] else { throw .invalidCode }
    if issued.age.elapsed() >= Self.codeLifetime { throw .codeExpired }
    guard issued.failedAttempts < Self.maxCodeAttempts, code == issued.code else {
      issued.failedAttempts += 1
      otpCodes[email] = issued
      throw .invalidCode
    }
    otpCodes[email] = nil
    if account.alwaysLocked || lockedEmails.contains(email) { throw .accountLocked }
    return MockAccounts.session(for: account.user)
  }

  /// Creates an unverified account and emails a verification code.
  public func register(name: String, email: String, password: String) throws(AuthError) {
    let email = normalized(email)
    guard accounts[email] == nil else { throw .emailTaken }
    guard isStrongPassword(password) else { throw .weakPassword }
    let user = User(id: "u\(nextUserNumber)", name: name, email: email)
    nextUserNumber += 1
    accounts[email] = MockAccount(user: user, password: password, isVerified: false)
    verificationCodes[email] = IssuedCode(code: MockAccounts.verificationCode, age: clock.stopwatch())
  }

  /// Checks the emailed code, marks the account verified and signs in.
  public func verifyEmail(email: String, code: String) throws(AuthError) -> Session {
    let email = normalized(email)
    guard let issued = verificationCodes[email], var account = accounts[email] else { throw .invalidCode }
    if issued.age.elapsed() >= Self.codeLifetime { throw .codeExpired }
    guard code == issued.code else { throw .invalidCode }
    verificationCodes[email] = nil
    account.isVerified = true
    accounts[email] = account
    return MockAccounts.session(for: account.user)
  }

  /// Emails a new verification code; blocked for 30 s after the previous one.
  public func resendVerification(email: String) throws(AuthError) {
    let email = normalized(email)
    guard let account = accounts[email], !account.isVerified else { throw .invalidCode }
    if let issued = verificationCodes[email], issued.age.elapsed() < Self.resendCooldown {
      throw .resendNotAvailable
    }
    verificationCodes[email] = IssuedCode(code: MockAccounts.verificationCode, age: clock.stopwatch())
  }

  /// "Continue with Google": always the Google test account, created (verified) if needed.
  public func signInWithGoogle() -> Session {
    let google = MockAccounts.google
    if accounts[google.user.email] == nil {
      accounts[google.user.email] = google
    }
    return MockAccounts.session(for: google.user)
  }

  public func requestPasswordReset(email: String) {
    let email = normalized(email)
    guard accounts[email] != nil else { return }
    resetCodes[email] = IssuedCode(code: MockAccounts.resetCode, age: clock.stopwatch())
  }

  public func resetPassword(email: String, code: String, newPassword: String) throws(AuthError) {
    let email = normalized(email)
    guard let issued = resetCodes[email], var account = accounts[email] else { throw .invalidCode }
    if issued.age.elapsed() >= Self.codeLifetime { throw .codeExpired }
    guard code == issued.code else { throw .invalidCode }
    guard isStrongPassword(newPassword) else { throw .weakPassword }
    account.password = newPassword
    accounts[email] = account
    resetCodes[email] = nil
    lockedEmails.remove(email)
    failedLogins[email] = nil
  }

  private func normalized(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespaces).lowercased()
  }
}

/// Measures time elapsed on a clock without storing its (existential) instants.
struct Stopwatch: Sendable {
  let elapsed: @Sendable () -> Duration
}

extension Clock where Duration == Swift.Duration {
  func stopwatch() -> Stopwatch {
    let start = now
    return Stopwatch { start.duration(to: self.now) }
  }
}

public enum AuthBackendKey: DependencyKey {
  public static let liveValue = AuthBackend(clock: ContinuousClock())
  public static var testValue: AuthBackend {
    reportIssue("AuthBackend is not overridden. Construct one explicitly with the test's clock.")
    return AuthBackend(clock: ContinuousClock())
  }
  public static var previewValue: AuthBackend { AuthBackend(clock: ContinuousClock()) }
}

extension DependencyValues {
  public var authBackend: AuthBackend {
    get { self[AuthBackendKey.self] }
    set { self[AuthBackendKey.self] = newValue }
  }
}
