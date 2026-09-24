import Foundation
import Models
import Testing

struct ValidationTests {
  @Test(arguments: [
    "alice@example.com",
    "a.b+tag@sub.example.co",
    "x@y.io",
  ])
  func validEmails(_ email: String) {
    #expect(isValidEmail(email))
  }

  @Test(arguments: [
    "",
    "alice",
    "alice@",
    "@example.com",
    "alice@example",
    "alice@example.c",
    "alice@@example.com",
    "alice@exa mple.com",
    "alice@example..com",
    "alice@example.c0m",
    " alice@example.com",
  ])
  func invalidEmails(_ email: String) {
    #expect(!isValidEmail(email))
  }

  @Test func passwordRules() {
    #expect(passwordIssues("Passw0rd!") == [])
    #expect(passwordIssues("abcdefg1") == [])
    #expect(passwordIssues("abcdef1") == [.tooShort])
    #expect(passwordIssues("abcdefgh") == [.missingDigit])
    #expect(passwordIssues("12345678") == [.missingLetter])
    #expect(passwordIssues("") == [.tooShort, .missingLetter, .missingDigit])
    #expect(isStrongPassword("Hunter22x"))
    #expect(!isStrongPassword("hunter"))
  }
}

struct FormattingTests {
  @Test func cents() {
    #expect(formatCents(0) == "$0.00")
    #expect(formatCents(5) == "$0.05")
    #expect(formatCents(100) == "$1.00")
    #expect(formatCents(5980) == "$59.80")
    #expect(formatCents(123_456) == "$1234.56")
    #expect(formatCents(-250) == "-$2.50")
  }

  @Test func days() {
    #expect(formatDay(day("2025-12-30")) == "2025-12-30")
    #expect(day("2026-01-01") == Date(timeIntervalSince1970: 1_767_225_600))
  }
}

struct OrderTests {
  @Test func totalsAndCancellability() {
    let order = Order(
      id: 1003,
      status: .pending,
      placedOn: day("2025-12-30"),
      items: [
        OrderItem(name: "Laptop Stand", quantity: 1, unitPriceCents: 3990),
        OrderItem(name: "USB-C Cable", quantity: 2, unitPriceCents: 950),
      ]
    )
    #expect(order.totalCents == 5890)
    #expect(order.isCancellable)
    var shipped = order
    shipped.status = .shipped
    #expect(!shipped.isCancellable)
  }

  @Test func codableRoundTrip() throws {
    let session = Session(user: User(id: "u1", name: "Alice", email: "alice@example.com"), token: "t")
    let order = Order(id: 1, status: .delivered, placedOn: day("2025-12-10"), items: [])
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(try decoder.decode(Session.self, from: encoder.encode(session)) == session)
    #expect(try decoder.decode(Order.self, from: encoder.encode(order)) == order)
  }

  @Test func errorCodesAreRawValues() {
    #expect(AuthError(rawValue: "accountLocked") == .accountLocked)
    #expect(OrdersError.notCancellable.rawValue == "notCancellable")
  }
}

struct ValidationIssueTests {
  @Test func mapping() {
    #expect(passwordIssues("abc").map(ValidationIssue.init) == [.passwordTooShort, .passwordMissingDigit])
    #expect(ValidationIssue.summary([]) == "none")
    #expect(ValidationIssue.summary([.email, .confirmMismatch]) == "email,confirmMismatch")
  }

  @Test func errorWrapping() {
    struct Other: Error {}
    #expect(AuthError(AuthError.emailTaken as any Error) == .emailTaken)
    #expect(AuthError(Other()) == .network)
    #expect(OrdersError(OrdersError.notFound as any Error) == .notFound)
    #expect(OrdersError(Other()) == .network)
  }
}
