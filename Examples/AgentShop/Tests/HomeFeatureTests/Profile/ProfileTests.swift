import AgentCtlCore
import ComposableArchitecture
import DeviceClients
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
    #expect(
      plain.summary == [
        SummaryItem("name", "Alice"), SummaryItem("email", "alice@example.com"), SummaryItem("orderUpdates", "off"),
        SummaryItem("faceID", "off"), SummaryItem("alert", "none"),
      ]
    )
    #expect(plain.command(named: "confirm")?.disabledReason == "alert=none")
    let alerting = Profile.activeScreen(Profile.State(user: alice, alert: .confirmLogout))
    #expect(alerting.command(named: "confirm")?.disabledReason == nil)
    #expect(alerting.summary.last == SummaryItem("alert", "logout"))
  }

  @Test func orderUpdatesNeedTheNotificationsPermission() async {
    let store = TestStore(initialState: Profile.State(user: alice)) { Profile() } withDependencies: {
      $0.notificationsClient.requestAuthorization = { .denied }
    }
    await store.send(.orderUpdatesToggled(true))
    await store.receive(\.notificationsAnswered) { $0.error = .notificationsDenied }
    store.dependencies.notificationsClient.requestAuthorization = { .granted }
    await store.send(.orderUpdatesToggled(true)) { $0.error = nil }
    await store.receive(\.notificationsAnswered) { $0.orderUpdates = true }
    await store.send(.orderUpdatesToggled(false)) { $0.orderUpdates = false }
  }

  @Test func faceIDKeepsTheSessionForTheLoginScreen() async {
    let session = Session(user: alice, token: "t")
    let vault = FaceIDVault()
    let store = TestStore(initialState: Profile.State(user: alice, session: session)) { Profile() } withDependencies: {
      $0.biometricsClient.authenticate = { .failure }
      $0.faceIDVault = vault
    }
    await store.send(.faceIDToggled(true))
    await store.receive(\.faceIDAnswered) { $0.error = .biometryFailed }
    store.dependencies.biometricsClient.authenticate = { .success }
    await store.send(.faceIDToggled(true)) { $0.error = nil }
    await store.receive(\.faceIDAnswered) { $0.faceID = true }
    #expect(vault.session == session)
    await store.send(.faceIDToggled(false)) { $0.faceID = false }
    #expect(vault.session == nil)
  }
}
