import AgentCtlCore
import Dependencies
import Foundation
import Observation

/// The app: the list at the root of a navigation stack, with detail screens pushed on top. It owns navigation
/// (`path`, which a `NavigationStack(path:)` would bind) and creates each pushed view model.
@MainActor
@Observable
public final class AppCoordinator {
  public enum Route: Hashable {
    case detail(ItemDetailViewModel)
  }

  /// One pushed screen. `id` is what TCA's `StackElementID` is: pushing the same path twice is a new appearance.
  public struct Element: Hashable {
    public let id: Int
    public let route: Route
  }

  public let items: ItemsViewModel
  public private(set) var path: [Element] = []
  /// Deterministic ids: a counter, not `UUID()`.
  @ObservationIgnored private var nextID = 0

  public init() {
    items = ItemsViewModel()
    items.onOpen = { [weak self] item in self?.push(item) }
  }

  func push(_ item: Item) {
    // Created inside this coordinator's dependencies, so its `@Dependency`s are the app's, not the ambient ones.
    let detail = withDependencies(from: self) { ItemDetailViewModel(item: item) }
    path.append(Element(id: nextID, route: .detail(detail)))
    nextID += 1
  }

  public func pop() {
    guard let element = path.popLast() else { return }
    switch element.route {
    case let .detail(detail): detail.cancelAllWork()
    }
  }

  /// A deep link or a tapped push: open that item on top of whatever is shown, as tapping it in the list would.
  public func openItem(_ id: Int) {
    items.openTapped(id)
  }
}

extension ItemDetailViewModel: Hashable {
  nonisolated public static func == (lhs: ItemDetailViewModel, rhs: ItemDetailViewModel) -> Bool { lhs === rhs }
  nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension AppCoordinator: AgentCoordinator {
  nonisolated static let backHelp = "Go back to the list."

  public func activeScreen() -> ActiveScreen<AppIntent<AppCoordinator>> {
    guard let top = path.last else {
      return items.activeScreen()
    }
    let child: ActiveScreen<AppIntent<AppCoordinator>> =
      switch top.route {
      case let .detail(detail): detail.activeScreen()
      }
    let back = AgentCommand<Void, AppIntent<AppCoordinator>>
      .action("back", help: Self.backHelp, AppIntent { $0.pop() })
      .resolve((), source: "AppCoordinator")
    return child.identified(by: "#\(top.id)").appending([back])
  }

  nonisolated public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "AppCoordinator")
    return ItemsViewModel.screenDocs + ItemDetailViewModel.screenDocs.map { $0.inheriting([back]) }
  }

  public func cancelAllWork() {
    items.cancelAllWork()
    for element in path {
      switch element.route {
      case let .detail(detail): detail.cancelAllWork()
      }
    }
  }

  public var agentStateDump: String {
    var lines = ["AppCoordinator(", "  items: ItemsViewModel(items: \(items.items.count), isLoading: \(items.isLoading), error: \(items.error.map { ".\($0)" } ?? "nil")),", "  path: ["]
    for element in path {
      switch element.route {
      case let .detail(detail):
        lines.append("    #\(element.id): .detail(item: \(detail.item.id), saved: \(detail.saved), cooldown: \(detail.cooldown), error: \(detail.error.map { ".\($0)" } ?? "nil")),")
      }
    }
    lines += ["  ]", ")"]
    return lines.joined(separator: "\n")
  }
}
