import ComposableArchitecture
import Models

/// Pick what you like: at least two categories, at most four. Picking a fifth is refused with `tooMany`
/// instead of being ignored.
@Reducer
public struct Interests {
  public static let minimum = 2
  public static let maximum = 4

  public enum Error: String, Equatable, Sendable {
    case tooMany
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    /// In the order they were picked.
    public var selected: [ProductCategory]
    public var error: Error?

    public init(selected: [ProductCategory] = [], error: Error? = nil) {
      self.selected = selected
      self.error = error
    }

    public var canContinue: Bool { selected.count >= Interests.minimum }
  }

  public enum Action: Sendable {
    case toggled(ProductCategory)
    case continueTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      case chose([ProductCategory])
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .toggled(category):
        if let index = state.selected.firstIndex(of: category) {
          state.selected.remove(at: index)
          state.error = nil
        } else if state.selected.count >= Self.maximum {
          state.error = .tooMany
        } else {
          state.selected.append(category)
          state.error = nil
        }
        return .none

      case .continueTapped:
        guard state.canContinue else { return .none }
        return .send(.delegate(.chose(state.selected)))

      case .delegate:
        return .none
      }
    }
  }
}
