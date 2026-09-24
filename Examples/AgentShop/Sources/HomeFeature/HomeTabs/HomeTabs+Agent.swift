import AgentCtlCore
import ComposableArchitecture

extension HomeTabs: AgentContainer {
  static let backHelp = "Go back to the previous screen."
  static let tabHelp = "Switch tab."

  static let tabCommand = AgentCommand<State, Action>.parsing(
    "tab",
    argument: "<orders|profile>",
    help: tabHelp
  ) { text throws(AgentCommandError) in
    guard let tab = Tab(rawValue: text) else { throw .invalidArgument("expected orders|profile") }
    return .tabSelected(tab)
  }

  public static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    var commands = [tabCommand.resolve(state, source: "HomeTabs")]
    let screen: ActiveScreen<Action>
    switch state.selectedTab {
    case .orders:
      if let id = state.ordersPath.ids.last, let top = state.ordersPath[id: id] {
        switch top {
        case let .detail(detail):
          screen = OrderDetail.activeScreen(detail)
            .map { .ordersPath(.element(id: id, action: .detail($0))) }
            .identified(by: id.debugDescription)
        }
        commands.append(
          AgentCommand<State, Action>.action("back", help: backHelp, .ordersPath(.popFrom(id: id)))
            .resolve(state, source: "HomeTabs")
        )
      } else {
        screen = OrdersList.activeScreen(state.ordersList).map { .ordersList($0) }
      }
    case .profile:
      screen = Profile.activeScreen(state.profile).map { .profile($0) }
    }
    return screen.identified(by: "home#\(state.id.uuidString)").appending(commands)
  }

  public static var registry: [ScreenDoc] {
    let tab = CommandDoc(name: "tab", argument: "<orders|profile>", help: tabHelp, source: "HomeTabs")
    let back = CommandDoc(name: "back", argument: nil, help: backHelp, source: "HomeTabs")
    return OrdersList.screenDocs.map { $0.inheriting([tab]) }
      + OrderDetail.screenDocs.map { $0.inheriting([tab, back]) }
      + Profile.screenDocs.map { $0.inheriting([tab]) }
  }
}
