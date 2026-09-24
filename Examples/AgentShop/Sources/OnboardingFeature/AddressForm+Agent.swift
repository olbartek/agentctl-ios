import AgentCtlCore
import ComposableArchitecture

extension AddressForm: AgentScreen {
  public static let screenPaths = ["onboarding/address"]

  public static func screenPath(_ state: State) -> String { "onboarding/address" }

  public static let summaryKeys = ["name", "street", "city", "zip", "canContinue"]

  public static func summary(_ state: State) -> [SummaryItem] {
    [
      SummaryItem("name", state.address.name),
      SummaryItem("street", state.address.street),
      SummaryItem("city", state.address.city),
      SummaryItem("zip", state.address.zip),
      SummaryItem("canContinue", state.canContinue),
    ]
  }

  public static func errorCode(_ state: State) -> String? { state.error?.rawValue }

  public static let commands: [AgentCommand<State, Action>] = [
    .text("name", help: "Set the full name.") { .binding(.set(\.address.name, $0)) },
    .text("street", help: "Set the street.") { .binding(.set(\.address.street, $0)) },
    .text("city", help: "Set the city.") { .binding(.set(\.address.city, $0)) },
    .text("zip", help: "Set the zip code (five digits).") { .binding(.set(\.address.zip, $0)) },
    .action(
      "continue",
      help: "Save the address for checkout; a zip that isn't five digits reports error=invalidZip.",
      gate: CommandGate(hint: "canContinue=false") { $0.canContinue },
      .continueTapped
    ),
    .action("skip", help: "Go on without an address.", .skipTapped),
  ]
}
