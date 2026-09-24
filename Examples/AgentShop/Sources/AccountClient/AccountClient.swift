import AgentCtlCore
import ComposableArchitecture
import Models
import SessionClient

/// The signed-in shopper's account: whether they still need onboarding, their interests and saved address.
/// Everything is mocked: `liveValue` talks to the in-memory ``AccountBackend`` and identifies the user from
/// ``SessionStorage``, the way a server reads a token.
@DependencyClient
public struct AccountClient: Sendable {
  public var fetchProfile: @Sendable () async throws -> AccountProfile
  public var completeOnboarding: @Sendable (_ answers: OnboardingAnswers) async throws -> AccountProfile
}

extension AccountClient: DependencyKey {
  public static let liveValue = AccountClient(
    fetchProfile: {
      try await accountCall("account.fetchProfile") { backend, email in await backend.profile(for: email) }
    },
    completeOnboarding: { answers in
      try await accountCall("account.completeOnboarding") { backend, email in
        await backend.completeOnboarding(answers, for: email)
      }
    }
  )

  public static let testValue = AccountClient()
  public static let previewValue = liveValue

  /// The methods `mock account.<method> <error>` accepts: only `network` (a signed-out call is a bug, not a
  /// scenario).
  public static let mockMethods: [MockMethod] = ["fetchProfile", "completeOnboarding"].map {
    MockMethod("account.\($0)", errorCodes: [AccountError.network.rawValue])
  }
}

extension DependencyValues {
  public var accountClient: AccountClient {
    get { self[AccountClient.self] }
    set { self[AccountClient.self] = newValue }
  }
}

private func accountCall<T: Sendable>(
  _ name: String,
  _ body: @Sendable (AccountBackend, String) async throws -> T
) async throws -> T {
  try await shopCall(name, error: { AccountError(rawValue: $0) ?? .network }) {
    @Dependency(\.sessionStorage) var sessionStorage
    @Dependency(\.accountBackend) var backend
    guard let email = sessionStorage.currentSession?.user.email else { throw AccountError.unauthorized }
    return try await body(backend, email)
  }
}
