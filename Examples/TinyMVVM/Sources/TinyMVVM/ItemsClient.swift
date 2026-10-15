// TinyApp's model and mocked client, as an MVVM-C app has them: the same data and the same `items.fetch`, no TCA.
import AgentCtlCore
import Dependencies
import DependenciesMacros

public struct Item: Equatable, Hashable, Identifiable, Sendable {
  public var id: Int
  public var title: String

  public static let seed: [Item] = [
    Item(id: 1, title: "First item"),
    Item(id: 2, title: "Second item"),
    Item(id: 3, title: "Third item"),
  ]
}

public enum ItemsError: String, Error, Equatable, Sendable {
  case network
  case timeout
  case notFound

  public init(_ error: any Error) {
    self = (error as? ItemsError) ?? .network
  }
}

@DependencyClient
public struct ItemsClient: Sendable {
  public var fetch: @Sendable () async throws -> [Item]
}

extension ItemsClient: DependencyKey {
  public static let liveValue = ItemsClient(
    fetch: {
      try await mockCall("items.fetch", error: { ItemsError(rawValue: $0) ?? .network }) { Item.seed }
    }
  )

  public static let testValue = ItemsClient()

  public static let fetchErrors: [ItemsError] = [.network, .timeout]

  public static let mockMethods: [MockMethod] = [
    MockMethod("items.fetch", errorCodes: fetchErrors.map(\.rawValue))
  ]
}

extension DependencyValues {
  public var itemsClient: ItemsClient {
    get { self[ItemsClient.self] }
    set { self[ItemsClient.self] = newValue }
  }
}
