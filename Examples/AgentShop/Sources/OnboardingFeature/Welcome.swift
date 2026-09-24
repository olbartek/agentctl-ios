import ComposableArchitecture

/// The welcome carousel: three pages, then interests. "Skip" goes straight to interests.
@Reducer
public struct Welcome {
  public static let pageCount = 3

  @ObservableState
  public struct State: Equatable, Sendable {
    /// 1-based, as a shopper reads "1 of 3".
    public var page: Int

    public init(page: Int = 1) {
      self.page = page
    }
  }

  public enum Action: Sendable {
    case nextTapped
    case skipTapped
    case backTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case finished
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .nextTapped:
        guard state.page < Self.pageCount else { return .send(.delegate(.finished)) }
        state.page += 1
        return .none

      case .skipTapped:
        return .send(.delegate(.finished))

      case .backTapped:
        state.page = max(1, state.page - 1)
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
