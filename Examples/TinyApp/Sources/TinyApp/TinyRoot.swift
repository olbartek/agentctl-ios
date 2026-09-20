import AgentCtlCore
import ComposableArchitecture

/// The app: the list at the root of a navigation stack, with a detail screen pushed on top.
///
/// The root reducer is the one type AgentCtl is generic over: `ScriptRunner<TinyRoot>` drives this store, and
/// `TinyRoot` resolves which screen an agent is looking at (see `TinyRoot+Agent.swift`).
@Reducer
public struct TinyRoot {
  @Reducer
  public enum Path {
    case detail(ItemDetail)
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var items: Items.State
    public var path: StackState<Path.State>

    public init(items: Items.State = Items.State(), path: StackState<Path.State> = StackState()) {
      self.items = items
      self.path = path
    }
  }

  public enum Action: Sendable {
    case items(Items.Action)
    case path(StackActionOf<Path>)
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.items, action: \.items) {
      Items()
    }
    Reduce { state, action in
      switch action {
      case let .items(.delegate(.open(item))):
        state.path.append(.detail(ItemDetail.State(item: item)))
        return .none

      case .items, .path:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
  }
}

extension TinyRoot.Path.State: Equatable, Sendable {}
extension TinyRoot.Path.Action: Sendable {}
