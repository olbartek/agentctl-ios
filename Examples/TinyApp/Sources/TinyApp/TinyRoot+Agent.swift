import AgentCtlCore
import ComposableArchitecture

/// A container resolves the screen an agent is looking at, lifts that screen's commands to its own action type,
/// and adds the commands it owns itself — here `back`, which pops the stack.
extension TinyRoot: AgentContainer {
  static let backHelp = "Go back to the list."

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    guard let id = state.path.ids.last, let top = state.path[id: id] else {
      return Items.activeScreen(state.items).map { .items($0) }
    }
    let child: ActiveScreen<Action> =
      switch top {
      case let .detail(screen):
        ItemDetail.activeScreen(screen).map { .path(.element(id: id, action: .detail($0))) }
      }
    let back = AgentCommand<State, Action>
      .action("back", help: backHelp, .path(.popFrom(id: id)))
      .resolve(state, source: "TinyRoot")
    // The stack element's id is part of the screen's identity, so pushing the same path twice counts as a new
    // appearance and the screen's `onAppear` is sent again.
    return child.identified(by: id.debugDescription).appending([back])
  }

  /// Every screen the app can show, for `screens` and the generated docs. Pushed screens inherit `back`.
  public static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "TinyRoot")
    return Items.screenDocs + ItemDetail.screenDocs.map { $0.inheriting([back]) }
  }
}
