import AgentCtlCore
import ComposableArchitecture

/// What an agent can see and do on the list. This is the whole of the screen's agent surface: a path, a
/// compact summary, an error code, the action that stands in for `onAppear`, and the commands.
extension Items: AgentScreen {
  public static let screenPaths = ["items"]

  public static func screenPath(_ state: State) -> String { "items" }

  public static let summaryKeys = ["items", "loading"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("items", state.items.count),
      SummaryItem("loading", state.isLoading),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  /// Headlessly there is no view to send this, so the runtime sends it when the screen becomes active.
  public static let onAppear: Action? = .onAppear

  /// A `gate:` mirrors a button that is disabled: instead of sending an action that could only do nothing, the
  /// runner refuses the command and tells the agent which condition closed it — `open is disabled here
  /// (items=0)`. The hint reads as the reason, and the generated docs show it as "disabled when items=0".
  public static let commands: [AgentCommand<State, Action>] = [
    .parsing(
      "open",
      argument: "<id>",
      help: "Open an item, e.g. open 2.",
      gate: CommandGate(hint: "items=0") { !$0.items.isEmpty }
    ) { text throws(AgentCommandError) in
      guard let id = Int(text) else { throw .invalidArgument("expected an item id such as 2") }
      return .openTapped(id)
    },
    .action("refresh", help: "Load the list again.", .refresh),
    .action(
      "retry",
      help: "Load the list again after a failure.",
      gate: CommandGate(hint: "error=none") { $0.error != nil },
      .retry
    ),
  ]
}
