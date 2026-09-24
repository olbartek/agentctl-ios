import AgentCtlCore
import ComposableArchitecture
import HomeFeature
import Models
import Testing

@MainActor
@Suite(.serialized)
struct ProfileTests {
  let alice = User(id: "u1", name: "Alice", email: "alice@example.com")

  @Test func confirmingTheAlertLogsOut() async {
    let store = TestStore(initialState: Profile.State(user: alice)) { Profile() }
    await store.send(.logoutTapped) { $0.alert = .confirmLogout }
    await store.send(.alert(.presented(.confirmLogout))) { $0.alert = nil }
    await store.receive(\.delegate.loggedOut)
  }

  @Test func dismissingTheAlertKeepsTheUserSignedIn() async {
    let store = TestStore(initialState: Profile.State(user: alice)) { Profile() }
    await store.send(.logoutTapped) { $0.alert = .confirmLogout }
    await store.send(.alert(.dismiss)) { $0.alert = nil }
  }

  @Test func agentCommandsFollowTheAlert() {
    let plain = Profile.activeScreen(Profile.State(user: alice))
    #expect(plain.summary == [SummaryItem("name", "Alice"), SummaryItem("email", "alice@example.com"), SummaryItem("alert", "none")])
    #expect(plain.command(named: "confirm")?.disabledReason == "alert=none")
    let alerting = Profile.activeScreen(Profile.State(user: alice, alert: .confirmLogout))
    #expect(alerting.command(named: "confirm")?.disabledReason == nil)
    #expect(alerting.summary.last == SummaryItem("alert", "logout"))
  }
}
