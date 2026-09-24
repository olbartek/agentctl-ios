/// A pragmatic `local@domain.tld` check: one `@`, no whitespace, a dotted domain with non-empty labels
/// and a top-level domain of at least two letters.
public func isValidEmail(_ email: String) -> Bool {
  let parts = email.split(separator: "@", omittingEmptySubsequences: false)
  guard parts.count == 2 else { return false }
  let local = parts[0]
  let domain = parts[1]
  guard !local.isEmpty, !email.contains(where: \.isWhitespace) else { return false }
  let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
  guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
  guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
  return true
}

/// Why a password is too weak. The raw value is the code agents see in `issues=`.
public enum PasswordIssue: String, CaseIterable, Hashable, Sendable {
  case tooShort
  case missingLetter
  case missingDigit
}

/// Password rules: at least 8 characters, with at least one letter and one digit.
public func passwordIssues(_ password: String) -> [PasswordIssue] {
  var issues: [PasswordIssue] = []
  if password.count < 8 { issues.append(.tooShort) }
  if !password.contains(where: \.isLetter) { issues.append(.missingLetter) }
  if !password.contains(where: \.isNumber) { issues.append(.missingDigit) }
  return issues
}

public func isStrongPassword(_ password: String) -> Bool {
  passwordIssues(password).isEmpty
}

/// A form validation problem. The raw value is the code agents see in `issues=`.
public enum ValidationIssue: String, CaseIterable, Hashable, Sendable {
  case email
  case passwordTooShort
  case passwordMissingLetter
  case passwordMissingDigit
  case confirmMismatch

  public init(_ issue: PasswordIssue) {
    switch issue {
    case .tooShort: self = .passwordTooShort
    case .missingLetter: self = .passwordMissingLetter
    case .missingDigit: self = .passwordMissingDigit
    }
  }

  /// `none`, or the codes joined by commas: `email,passwordTooShort`.
  public static func summary(_ issues: [ValidationIssue]) -> String {
    issues.isEmpty ? "none" : issues.map(\.rawValue).joined(separator: ",")
  }
}
