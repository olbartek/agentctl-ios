import Models

/// Human-readable messages for backend errors. Kept here so every screen words errors the same way.
extension AuthError {
  public var message: String {
    switch self {
    case .invalidCredentials: "Please enter correct password"
    case .accountLocked: "This account is locked. Reset your password to unlock it."
    case .unknownEmail: "No account uses this email."
    case .invalidCode: "That code is not valid."
    case .codeExpired: "That code has expired. Request a new one."
    case .resendNotAvailable: "Wait before requesting another code."
    case .emailTaken: "An account with this email already exists."
    case .weakPassword: "Choose a stronger password."
    case .emailNotVerified: "Verify your email address first. Check your inbox for the code."
    case .network: "The network is unreachable. Try again."
    }
  }
}

extension OrdersError {
  public var message: String {
    switch self {
    case .notFound: "This order does not exist."
    case .notCancellable: "This order can no longer be cancelled."
    case .paymentDeclined: "Your card was declined. Try another card or Apple Pay."
    case .network: "The network is unreachable. Try again."
    case .unauthorized: "You are signed out."
    }
  }
}

extension AccountError {
  public var message: String {
    switch self {
    case .network: "The network is unreachable. Try again."
    case .unauthorized: "You are signed out."
    }
  }
}

extension PasswordIssue {
  public var message: String {
    switch self {
    case .tooShort: "Use at least 8 characters."
    case .missingLetter: "Include at least one letter."
    case .missingDigit: "Include at least one digit."
    }
  }
}

extension ValidationIssue {
  public var message: String {
    switch self {
    case .email: "Enter a valid email address."
    case .passwordTooShort: "Use at least 8 characters."
    case .passwordMissingLetter: "Include at least one letter."
    case .passwordMissingDigit: "Include at least one digit."
    case .confirmMismatch: "The passwords don't match."
    }
  }
}

extension Array where Element == ValidationIssue {
  /// The issues' messages as one line, or `nil` when there are none (a field's error line).
  public var message: String? {
    isEmpty ? nil : map(\.message).joined(separator: " ")
  }
}
