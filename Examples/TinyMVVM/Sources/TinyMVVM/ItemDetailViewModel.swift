import AgentCtlCore
import Dependencies
import Observation

/// The detail screen: it saves the item, then refuses to save again until a three-second cooldown has run out. The
/// countdown is a task sleeping on `\.continuousClock`, so a step reports it as `pending=1` and `advance` releases it.
@MainActor
@Observable
public final class ItemDetailViewModel {
  public enum SaveError: String, Equatable, Sendable {
    case cooldown
  }

  nonisolated public static let cooldownSeconds = 3

  public let item: Item
  public private(set) var saved = false
  public private(set) var cooldown = 0
  public private(set) var error: SaveError?

  @ObservationIgnored @Dependency(\.continuousClock) private var clock
  @ObservationIgnored @Dependency(\.agentTasks) private var tasks
  @ObservationIgnored private var cooldownTask: Task<Void, Never>?

  public init(item: Item) {
    self.item = item
  }

  public func saveTapped() {
    guard cooldown == 0 else {
      error = .cooldown
      return
    }
    error = nil
    saved = true
    cooldown = Self.cooldownSeconds
    cooldownTask?.cancel()
    cooldownTask = tasks.run(for: self) { [weak self, clock] in
      for await _ in clock.timer(interval: .seconds(1)) {
        guard !Task.isCancelled, let self else { return }
        self.cooldownTicked()
      }
    }
  }

  private func cooldownTicked() {
    cooldown = max(0, cooldown - 1)
    guard cooldown == 0 else { return }
    error = nil
    cooldownTask?.cancel()
  }

  /// TCA cancels a popped stack element's effects for you; here the coordinator calls this when it pops.
  func cancelAllWork() {
    cooldownTask?.cancel()
  }
}

extension ItemDetailViewModel: AgentViewModel {
  public struct AgentState: Equatable, Sendable {
    var item: Item
    var saved: Bool
    var cooldown: Int
    var error: SaveError?
  }

  public var agentState: AgentState { AgentState(item: item, saved: saved, cooldown: cooldown, error: error) }

  nonisolated public static var screenName: String { "ItemDetail" }
  nonisolated public static let screenPaths = ["items/<id>"]
  nonisolated public static func screenPath(_ state: AgentState) -> String { "items/\(state.item.id)" }
  nonisolated public static let summaryKeys = ["title", "saved", "cooldown"]

  nonisolated public static func summary(_ state: AgentState) -> [SummaryItem] {
    [
      SummaryItem("title", state.item.title),
      SummaryItem("saved", state.saved),
      SummaryItem("cooldown", state.cooldown),
    ]
  }

  nonisolated public static func errorCode(_ state: AgentState) -> String? { state.error?.rawValue }

  nonisolated public static var commands: [AgentCommand<AgentState, AgentScreenIntent<ItemDetailViewModel>>] {
    [
      .action(
        "save",
        help: "Save this item. A save starts a \(cooldownSeconds)-second cooldown; saving again "
          + "before it runs out reports error=cooldown.",
        AgentScreenIntent { $0.saveTapped() }
      )
    ]
  }
}
