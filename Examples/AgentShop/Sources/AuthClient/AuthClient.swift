import AgentCtlCore
import ComposableArchitecture
import Models

/// Authentication endpoints. Everything is mocked: `liveValue` talks to the in-memory ``AuthBackend``.
@DependencyClient
public struct AuthClient: Sendable {
  public var login: @Sendable (_ email: String, _ password: String) async throws -> Session
  public var sendOTP: @Sendable (_ email: String) async throws -> Void
  public var verifyOTP: @Sendable (_ email: String, _ code: String) async throws -> Session
  /// Creates an unverified account and emails a verification code (see `verifyEmail`).
  public var register: @Sendable (_ name: String, _ email: String, _ password: String) async throws -> Void
  public var verifyEmail: @Sendable (_ email: String, _ code: String) async throws -> Session
  public var resendVerification: @Sendable (_ email: String) async throws -> Void
  public var signInWithGoogle: @Sendable () async throws -> Session
  /// Always succeeds, so the app never reveals which accounts exist.
  public var requestPasswordReset: @Sendable (_ email: String) async throws -> Void
  public var resetPassword: @Sendable (_ email: String, _ code: String, _ newPassword: String) async throws -> Void
}

extension AuthClient: DependencyKey {
  public static let liveValue = AuthClient(
    login: { email, password in
      try await authCall("auth.login") { try await $0.login(email: email, password: password) }
    },
    sendOTP: { email in
      try await authCall("auth.sendOTP") { try await $0.sendOTP(email: email) }
    },
    verifyOTP: { email, code in
      try await authCall("auth.verifyOTP") { try await $0.verifyOTP(email: email, code: code) }
    },
    register: { name, email, password in
      try await authCall("auth.register") { try await $0.register(name: name, email: email, password: password) }
    },
    verifyEmail: { email, code in
      try await authCall("auth.verifyEmail") { try await $0.verifyEmail(email: email, code: code) }
    },
    resendVerification: { email in
      try await authCall("auth.resendVerification") { try await $0.resendVerification(email: email) }
    },
    signInWithGoogle: {
      try await authCall("auth.signInWithGoogle") { await $0.signInWithGoogle() }
    },
    requestPasswordReset: { email in
      try await authCall("auth.requestPasswordReset") { await $0.requestPasswordReset(email: email) }
    },
    resetPassword: { email, code, newPassword in
      try await authCall("auth.resetPassword") {
        try await $0.resetPassword(email: email, code: code, newPassword: newPassword)
      }
    }
  )

  public static let testValue = AuthClient()
  public static let previewValue = liveValue

  /// The methods `mock auth.<method> <error>` accepts, with their error codes.
  public static let mockMethods: [MockMethod] = [
    "login", "sendOTP", "verifyOTP", "register", "verifyEmail", "resendVerification", "signInWithGoogle",
    "requestPasswordReset", "resetPassword",
  ].map { MockMethod("auth.\($0)", errorCodes: AuthError.allCases.map(\.rawValue)) }
}

extension DependencyValues {
  public var authClient: AuthClient {
    get { self[AuthClient.self] }
    set { self[AuthClient.self] = newValue }
  }
}

private func authCall<T: Sendable>(
  _ name: String,
  _ body: @Sendable (AuthBackend) async throws -> T
) async throws -> T {
  try await mockCall(name, error: { AuthError(rawValue: $0) ?? .network }) {
    @Dependency(\.authBackend) var backend
    return try await body(backend)
  }
}
