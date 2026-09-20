import AgentCtlCore
import ComposableArchitecture

/// The detail screen: it saves the item, then refuses to save again until a three-second cooldown has run out.
///
/// The cooldown is what makes this screen interesting to an agent: it is an effect suspended on
/// `@Dependency(\.continuousClock)`, so a step reports it as `pending=1`, and headlessly `advance 3s` releases
/// it instead of waiting three real seconds.
@Reducer
public struct ItemDetail {
  /// Why a save was refused. The raw value is what an agent sees as `error=cooldown`.
  public enum SaveError: String, Equatable, Sendable {
    case cooldown
  }

  @ObservableState
  public struct State: Equatable, Sendable {
    public var item: Item
    public var saved = false
    /// Seconds left before the item can be saved again; `0` when it can.
    public var cooldown = 0
    public var error: SaveError?

    public init(item: Item) {
      self.item = item
    }
  }

  public enum Action: Sendable {
    case saveTapped
    case cooldownTicked
  }

  enum CancelID { case cooldown }

  /// The countdown a `save` starts, in seconds.
  public static let cooldownSeconds = 3

  @Dependency(\.continuousClock) var clock

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .saveTapped:
        // The guard lives in the reducer, so a save that arrives during the cooldown is answered with
        // `error=cooldown` rather than silently ignored. A screen whose button is merely greyed out would
        // instead pass a `gate:` to the command in `ItemDetail+Agent.swift`, and the runner would refuse the
        // command before it ever reached here.
        guard state.cooldown == 0 else {
          state.error = .cooldown
          return .none
        }
        state.error = nil
        state.saved = true
        state.cooldown = Self.cooldownSeconds
        return .run { [clock] send in
          for await _ in clock.timer(interval: .seconds(1)) {
            await send(.cooldownTicked)
          }
        }
        .cancellable(id: CancelID.cooldown, cancelInFlight: true)

      case .cooldownTicked:
        state.cooldown = max(0, state.cooldown - 1)
        guard state.cooldown == 0 else { return .none }
        // Saving is possible again, so the refusal no longer applies.
        state.error = nil
        return .cancel(id: CancelID.cooldown)
      }
    }
  }
}
