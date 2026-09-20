import AgentCtlCore
import ComposableArchitecture

/// One row of the list.
public struct Item: Equatable, Identifiable, Sendable {
  public var id: Int
  public var title: String

  public init(id: Int, title: String) {
    self.id = id
    self.title = title
  }

  /// What every fetch returns. A real app would have a server here; a constant is enough to drive the screens.
  public static let seed: [Item] = [
    Item(id: 1, title: "First item"),
    Item(id: 2, title: "Second item"),
    Item(id: 3, title: "Third item"),
  ]
}

/// Everything the list can report as `error=<code>`.
///
/// The raw values are what an agent sees and asserts on, so keep them short and stable. Two of them are what
/// ``ItemsClient/fetch`` can throw and `mock items.fetch <code>` can force; `notFound` is the screen's own, for
/// an `open <id>` that names an item the list does not have. That is why ``ItemsClient/fetchErrors`` lists the
/// client's codes explicitly instead of taking every case: `mock items.fetch notFound` is rightly rejected.
public enum ItemsError: String, Error, Equatable, Sendable {
  case network
  case timeout
  case notFound

  /// Anything else becomes `network`, so `error=` is always one of the documented codes.
  public init(_ error: any Error) {
    self = (error as? ItemsError) ?? .network
  }
}

/// The app's one client. Everything is mocked, and every method goes through ``mockCall`` so that the call
/// shows up as `calls=items.fetch` in the step output and can be made to fail with `mock`.
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

  /// What a fetch can throw — not every ``ItemsError``, because `notFound` is the screen's, not the client's.
  public static let fetchErrors: [ItemsError] = [.network, .timeout]

  /// The methods `mock <method> <error>` accepts, with the errors each one can be made to throw. The CLI and
  /// the generated docs list exactly these.
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
