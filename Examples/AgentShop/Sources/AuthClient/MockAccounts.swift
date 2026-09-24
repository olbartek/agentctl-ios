import Models

/// A seeded account in the mock auth backend.
public struct MockAccount: Equatable, Sendable {
  public var user: User
  /// `nil` for accounts that can never sign in with a password.
  public var password: String?
  public var alwaysLocked: Bool
  /// Registered accounts start unverified until the emailed code is entered.
  public var isVerified: Bool

  public init(user: User, password: String?, alwaysLocked: Bool = false, isVerified: Bool = true) {
    self.user = user
    self.password = password
    self.alwaysLocked = alwaysLocked
    self.isVerified = isVerified
  }
}

/// The test accounts listed in `AGENTS.md`.
public enum MockAccounts {
  public static let alice = MockAccount(
    user: User(id: "u1", name: "Alice", email: "alice@example.com"),
    password: "Passw0rd!"
  )
  public static let bob = MockAccount(
    user: User(id: "u2", name: "Bob", email: "bob@example.com"),
    password: "Hunter22x"
  )
  public static let locked = MockAccount(
    user: User(id: "u3", name: "Locked", email: "locked@example.com"),
    password: nil,
    alwaysLocked: true
  )

  /// The account "Sign in with Google" returns (the design's persona). It has no password.
  public static let google = MockAccount(
    user: User(id: "u-google", name: "Becca Ade", email: "becca@gmail.com"),
    password: nil
  )

  public static let seed = [alice, bob, locked, google]

  /// The one-time login code. Always the same in the mock backend.
  public static let otpCode = "123456"
  /// The code emailed after registration. Always the same in the mock backend.
  public static let verificationCode = "123456"
  /// The password-reset code. Always the same in the mock backend.
  public static let resetCode = "654321"

  public static func session(for user: User) -> Session {
    Session(user: user, token: "mock-token-\(user.id)")
  }

  /// The session `login-as <name>` saves, for `alice` and `bob`.
  public static func session(named name: String) -> Session? {
    switch name {
    case "alice": session(for: alice.user)
    case "bob": session(for: bob.user)
    default: nil
    }
  }
}
