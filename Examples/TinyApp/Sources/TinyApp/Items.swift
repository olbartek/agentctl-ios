import AgentCtlCore
import ComposableArchitecture

/// The list screen: it loads when it appears, can be refreshed, and opens an item.
///
/// A failed load keeps the rows that were already there and reports the error, the way a real list does.
@Reducer
public struct Items {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var items: [Item] = []
    public var isLoading = false
    public var error: ItemsError?

    public init() {}
  }

  public enum Action: Sendable {
    case onAppear
    case refresh
    /// The error state's "Try again": the same load, offered only while there is a failure to clear.
    case retry
    case response(Result<[Item], ItemsError>)
    case openTapped(Int)
    case delegate(Delegate)

    /// What the screen tells its container. A screen never navigates by itself.
    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case open(Item)
    }
  }

  enum CancelID { case load }

  @Dependency(\.itemsClient) var client

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear, .refresh, .retry:
        state.isLoading = true
        state.error = nil
        return .run { [client] send in
          // `Result { try await … }` does not compile: `Result.init(catching:)` is synchronous.
          do {
            await send(.response(.success(try await client.fetch())))
          } catch {
            await send(.response(.failure(ItemsError(error))))
          }
        }
        .cancellable(id: CancelID.load, cancelInFlight: true)

      case let .response(.success(items)):
        state.isLoading = false
        state.items = items
        return .none

      case let .response(.failure(error)):
        state.isLoading = false
        state.error = error
        return .none

      case let .openTapped(id):
        // Never silently do nothing: an agent that asks for an item the list does not have is told so, the same
        // way a person would see it. A no-op would report a successful step and no error at all.
        guard let item = state.items.first(where: { $0.id == id }) else {
          state.error = .notFound
          return .none
        }
        state.error = nil
        return .send(.delegate(.open(item)))

      case .delegate:
        return .none
      }
    }
  }
}
