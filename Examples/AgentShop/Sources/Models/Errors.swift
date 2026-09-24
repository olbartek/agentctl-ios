/// Errors from the auth backend. The raw value is the code agents see as `error=<code>`.
public enum AuthError: String, Error, Codable, CaseIterable, Hashable, Sendable {
  case invalidCredentials
  case accountLocked
  case unknownEmail
  case invalidCode
  case codeExpired
  case resendNotAvailable
  case emailTaken
  case weakPassword
  /// The account was registered but its email address hasn't been verified yet.
  case emailNotVerified
  case network
}

/// Errors from the orders backend. The raw value is the code agents see as `error=<code>`.
public enum OrdersError: String, Error, Codable, CaseIterable, Hashable, Sendable {
  case notFound
  case notCancellable
  case network
  /// No session. Normal flows never hit this; it guards against calling orders while logged out.
  case unauthorized
}

extension AuthError {
  /// Any error from the auth client as an `AuthError`; unexpected errors count as `network`.
  public init(_ error: any Error) {
    self = error as? AuthError ?? .network
  }
}

extension OrdersError {
  /// Any error from the orders client as an `OrdersError`; unexpected errors count as `network`.
  public init(_ error: any Error) {
    self = error as? OrdersError ?? .network
  }
}
