import AgentCtlCore
import AuthClient
import ComposableArchitecture
import Models
import Testing

/// The live client is the mock shim: it logs calls, honours faults and latency, and delegates to the backend.
struct AuthClientLiveTests {
  @Test func logsCallsAndDelegatesToTheBackend() async throws {
    let log = MockCallLog()
    try await withDependencies {
      $0.mockCallLog = log
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
      $0.authBackend = AuthBackend(clock: TestClock())
    } operation: {
      let client = AuthClient.liveValue
      let session = try await client.login(email: "alice@example.com", password: "Passw0rd!")
      #expect(session.user.name == "Alice")
      try await client.sendOTP(email: "bob@example.com")
      _ = try await client.verifyOTP(email: "bob@example.com", code: "123456")
      try await client.requestPasswordReset(email: "bob@example.com")
      try await client.resetPassword(email: "bob@example.com", code: "654321", newPassword: "Another1x")
      try await client.register("Dan", "dan@example.com", "Secret123")
      _ = try await client.verifyEmail(email: "dan@example.com", code: "123456")
      _ = try await client.signInWithGoogle()
    }
    #expect(
      log.entries == [
        "auth.login", "auth.sendOTP", "auth.verifyOTP", "auth.requestPasswordReset", "auth.resetPassword",
        "auth.register", "auth.verifyEmail", "auth.signInWithGoogle",
      ]
    )
  }

  @Test func faultsBecomeTypedErrors() async throws {
    let faults = MockFaults()
    faults.set("auth.login", code: "network")
    try await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = faults
      $0.mockLatency = .zero
      $0.authBackend = AuthBackend(clock: TestClock())
    } operation: {
      await #expect(throws: AuthError.network) {
        try await AuthClient.liveValue.login(email: "alice@example.com", password: "Passw0rd!")
      }
      let session = try await AuthClient.liveValue.login(email: "alice@example.com", password: "Passw0rd!")
      #expect(session.user.name == "Alice")
    }
  }

  @Test func backendErrorsPassThrough() async {
    await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
      $0.authBackend = AuthBackend(clock: TestClock())
    } operation: {
      await #expect(throws: AuthError.accountLocked) {
        try await AuthClient.liveValue.login(email: "locked@example.com", password: "x")
      }
    }
  }

  @Test func mockMethods() {
    #expect(AuthClient.mockMethods.map(\.name).contains("auth.verifyOTP"))
    #expect(AuthClient.mockMethods[0].errorCodes.contains("network"))
  }
}
