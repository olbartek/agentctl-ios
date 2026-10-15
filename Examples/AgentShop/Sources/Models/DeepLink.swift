import Foundation

/// The links AgentShop opens: `agentshop://product/<id>`, `agentshop://order/<id>` and `agentshop://shop`.
public enum DeepLink: Equatable, Sendable {
  case product(Int)
  case order(Int)
  case shop

  /// `nil` for a URL that is not one of AgentShop's links.
  public init?(url: URL) {
    guard url.scheme == "agentshop", let host = url.host else { return nil }
    let path = url.pathComponents.filter { $0 != "/" }
    switch (host, path.count) {
    case ("shop", 0):
      self = .shop
    case ("product", 1):
      guard let id = Int(path[0]) else { return nil }
      self = .product(id)
    case ("order", 1):
      guard let id = Int(path[0]) else { return nil }
      self = .order(id)
    default:
      return nil
    }
  }
}
