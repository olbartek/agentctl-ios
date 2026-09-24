import ComposableArchitecture
import Models

/// A shipping address, saved for checkout. Optional: "Skip" moves on without one. "Continue" needs every field,
/// and a zip that is not five digits is refused with `invalidZip`.
@Reducer
public struct AddressForm {
  public enum Error: String, Equatable, Sendable {
    case invalidZip
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var address: Address
    public var error: Error?

    public init(address: Address = Address(), error: Error? = nil) {
      self.address = address
      self.error = error
    }

    public var canContinue: Bool { address.isComplete }
  }

  public enum Action: BindableAction, Sendable {
    case binding(BindingAction<State>)
    case continueTapped
    case skipTapped
    case delegate(Delegate)

    @CasePathable
    public enum Delegate: Equatable, Sendable {
      /// `nil` when skipped.
      case finished(Address?)
    }
  }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.error = nil
        return .none

      case .continueTapped:
        guard state.canContinue else { return .none }
        guard isValidZip(state.address.zip) else {
          state.error = .invalidZip
          return .none
        }
        return .send(.delegate(.finished(state.address)))

      case .skipTapped:
        return .send(.delegate(.finished(nil)))

      case .delegate:
        return .none
      }
    }
  }
}
