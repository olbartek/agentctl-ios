import AgentCtlCore
import ComposableArchitecture
import Models

/// Errors from the cart server. The raw value is the code agents see as `error=<code>`.
public enum CartError: String, Error, Codable, CaseIterable, Hashable, Sendable {
  case invalidPromo
  case network

  public init(_ error: any Error) {
    self = error as? CartError ?? .network
  }
}

/// A promo code the server accepted.
public struct Promo: Codable, Equatable, Hashable, Sendable {
  public var code: String
  public var percentOff: Int

  public init(code: String, percentOff: Int) {
    self.code = code
    self.percentOff = percentOff
  }

  public func discount(on subtotalCents: Int) -> Int {
    subtotalCents * percentOff / 100
  }
}

/// Promo codes. Everything is mocked: `SAVE10` is 10 % off, `HALF` 50 %; any other code is `invalidPromo`.
@DependencyClient
public struct CartClient: Sendable {
  public var applyPromo: @Sendable (_ code: String) async throws -> Promo
}

extension CartClient: DependencyKey {
  public static let promos = ["SAVE10": 10, "HALF": 50]

  public static let liveValue = CartClient(
    applyPromo: { code in
      try await shopCall("cart.applyPromo", error: { CartError(rawValue: $0) ?? .network }) {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let percent = promos[normalized] else { throw CartError.invalidPromo }
        return Promo(code: normalized, percentOff: percent)
      }
    }
  )

  public static let testValue = CartClient()
  public static let previewValue = liveValue

  /// Only `network`: an unknown code is how a script gets `invalidPromo`.
  public static let mockMethods: [MockMethod] = [MockMethod("cart.applyPromo", errorCodes: [CartError.network.rawValue])]
}

extension DependencyValues {
  public var cartClient: CartClient {
    get { self[CartClient.self] }
    set { self[CartClient.self] = newValue }
  }
}
