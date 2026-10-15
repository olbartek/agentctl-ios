import AgentCtlCore
import Dependencies
import Observation

/// The list, as a view model: it loads when it appears, can be refreshed, and asks the coordinator to open an item.
@MainActor
@Observable
public final class ItemsViewModel {
  public private(set) var items: [Item] = []
  public private(set) var isLoading = false
  public private(set) var error: ItemsError?

  /// The coordinator's: a view model never navigates by itself.
  @ObservationIgnored var onOpen: (Item) -> Void = { _ in }
  @ObservationIgnored @Dependency(\.itemsClient) private var client
  @ObservationIgnored @Dependency(\.agentTasks) private var tasks
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  public init() {}

  public func onAppear() { load() }
  public func refresh() { load() }
  public func retry() { load() }

  /// TCA's `.cancellable(id:cancelInFlight: true)` by hand: cancel the previous load, and never apply a cancelled
  /// load's result (TCA drops a cancelled effect's actions for you).
  private func load() {
    isLoading = true
    error = nil
    loadTask?.cancel()
    loadTask = tasks.run(for: self) { [weak self, client] in
      do {
        let items = try await client.fetch()
        guard !Task.isCancelled, let self else { return }
        self.isLoading = false
        self.items = items
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.isLoading = false
        self.error = ItemsError(error)
      }
    }
  }

  public func openTapped(_ id: Int) {
    guard let item = items.first(where: { $0.id == id }) else {
      error = .notFound
      return
    }
    error = nil
    onOpen(item)
  }

  func cancelAllWork() {
    loadTask?.cancel()
  }
}

extension ItemsViewModel: AgentViewModel {
  /// What the summary, error and gates read: the view model's state as a value.
  public struct AgentState: Equatable, Sendable {
    var items: Int
    var isLoading: Bool
    var error: ItemsError?
  }

  public var agentState: AgentState { AgentState(items: items.count, isLoading: isLoading, error: error) }

  nonisolated public static var screenName: String { "Items" }
  nonisolated public static let screenPaths = ["items"]
  nonisolated public static func screenPath(_ state: AgentState) -> String { "items" }
  nonisolated public static let summaryKeys = ["items", "loading"]

  nonisolated public static func summary(_ state: AgentState) -> [SummaryItem] {
    [SummaryItem("items", state.items), SummaryItem("loading", state.isLoading)]
  }

  nonisolated public static func errorCode(_ state: AgentState) -> String? { state.error?.rawValue }

  nonisolated public static var onAppear: ScreenIntent<ItemsViewModel>? { ScreenIntent { $0.onAppear() } }

  nonisolated public static var commands: [AgentCommand<AgentState, ScreenIntent<ItemsViewModel>>] {
    [
      .parsing(
        "open",
        argument: "<id>",
        help: "Open an item, e.g. open 2.",
        gate: CommandGate(hint: "items=0") { $0.items > 0 }
      ) { text throws(AgentCommandError) in
        guard let id = Int(text) else { throw .invalidArgument("expected an item id such as 2") }
        return ScreenIntent { $0.openTapped(id) }
      },
      .action("refresh", help: "Load the list again.", ScreenIntent { $0.refresh() }),
      .action(
        "retry",
        help: "Load the list again after a failure.",
        gate: CommandGate(hint: "error=none") { $0.error != nil },
        ScreenIntent { $0.retry() }
      ),
    ]
  }
}
