/// A registered user of the (mock) backend.
public struct User: Codable, Equatable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var email: String

  public init(id: String, name: String, email: String) {
    self.id = id
    self.name = name
    self.email = email
  }
}

/// An authenticated session, as returned by every successful sign-in.
public struct Session: Codable, Equatable, Hashable, Sendable {
  public var user: User
  public var token: String

  public init(user: User, token: String) {
    self.user = user
    self.token = token
  }
}
