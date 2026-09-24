import AccountClient
import AgentCtlCore
import AppFeature
import AuthClient
import AuthFeature
import ComposableArchitecture
import Foundation
import HomeFeature
import Models
import OnboardingFeature
import SessionClient
import Testing

@MainActor
@Suite(.serialized)
struct AppFeatureTests {
  let alice = MockAccounts.session(named: "alice")!

  @Test func launchWithoutASessionShowsAuth() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.current = { nil }
    }
    await store.send(.appeared)
    await store.receive(\.sessionLoaded) { $0 = .auth(AuthFlow.State()) }
  }

  @Test func launchWithASessionRestoresHome() async {
    let alice = alice
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.current = { alice }
      $0.uuid = .incrementing
    }
    await store.send(.appeared)
    await store.receive(\.sessionLoaded) { $0 = .home(HomeTabs.State(id: UUID(0), session: alice)) }
  }

  @Test func appearingAgainAfterLaunchDoesNothing() async {
    let store = TestStore(initialState: .auth(AuthFlow.State())) { AppFeature() }
    await store.send(.appeared)
  }

  @Test(arguments: [true, false])
  func authenticationSavesTheSessionThenGoesHome(remember: Bool) async {
    let saved = LockIsolated<StoredSession?>(nil)
    let store = TestStore(initialState: .auth(AuthFlow.State())) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.save = { saved.setValue(StoredSession(session: $0, remember: $1)) }
      $0.accountClient.fetchProfile = { AccountProfile(needsOnboarding: false) }
      $0.uuid = .incrementing
    }
    await store.send(.auth(.delegate(.authenticated(alice, remember: remember))))
    await store.receive(\.signedIn) { $0 = .home(HomeTabs.State(id: UUID(0), session: self.alice)) }
    #expect(saved.value == StoredSession(session: alice, remember: remember))
  }

  @Test func aNewAccountIsOnboardedThenGoesHome() async {
    let nina = MockAccounts.session(for: MockAccounts.nina.user)
    let store = TestStore(initialState: .auth(AuthFlow.State())) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.save = { _, _ in }
      $0.accountClient.fetchProfile = { AccountProfile(needsOnboarding: true) }
      $0.uuid = .incrementing
    }
    await store.send(.auth(.delegate(.authenticated(nina, remember: true))))
    await store.receive(\.signedIn) { $0 = .onboarding(OnboardingFlow.State(session: nina)) }
    await store.send(.onboarding(.delegate(.finished(nina)))) {
      $0 = .home(HomeTabs.State(id: UUID(0), session: nina))
    }
  }

  @Test func aFailedProfileLoadStillGoesHome() async {
    let store = TestStore(initialState: .auth(AuthFlow.State())) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.save = { _, _ in }
      $0.accountClient.fetchProfile = { throw AccountError.network }
      $0.uuid = .incrementing
    }
    await store.send(.auth(.delegate(.authenticated(alice, remember: true))))
    await store.receive(\.signedIn) { $0 = .home(HomeTabs.State(id: UUID(0), session: self.alice)) }
  }

  @Test func loggingOutClearsTheSessionAndShowsAFreshAuth() async {
    let cleared = LockIsolated(false)
    let store = TestStore(initialState: .home(HomeTabs.State(id: UUID(0), session: alice))) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.clear = { cleared.setValue(true) }
    }
    await store.send(.home(.delegate(.loggedOut)))
    await store.receive(\.signedOut) { $0 = .auth(AuthFlow.State()) }
    #expect(cleared.value)
  }

  @Test func loginAsSavesTheSessionAndGoesHome() async {
    let saved = LockIsolated<StoredSession?>(nil)
    let bob = MockAccounts.session(named: "bob")!
    let store = TestStore(initialState: .auth(AuthFlow.State())) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.save = { saved.setValue(StoredSession(session: $0, remember: $1)) }
      $0.accountClient.fetchProfile = { AccountProfile(needsOnboarding: false) }
      $0.uuid = .incrementing
    }
    await store.send(.loginAs(bob))
    await store.receive(\.signedIn) { $0 = .home(HomeTabs.State(id: UUID(0), session: bob)) }
    #expect(saved.value == StoredSession(session: bob, remember: true))
  }

  @Test func resetRelaunchesAndRestoresTheSession() async {
    let alice = alice
    let store = TestStore(initialState: .home(HomeTabs.State(id: UUID(0), session: alice))) {
      AppFeature()
    } withDependencies: {
      $0.sessionClient.current = { alice }
      $0.uuid = .incrementing
    }
    await store.send(.reset) { $0 = .launching }
    await store.send(.appeared)
    await store.receive(\.sessionLoaded) { $0 = .home(HomeTabs.State(id: UUID(0), session: alice)) }
  }

  @Test func rootAgentCommands() throws {
    let launching = AppFeature.activeScreen(.launching)
    #expect(launching.path == "launching")
    #expect(launching.commands.map(\.name) == ["login-as", "reset", "back"])
    #expect(launching.appearAction != nil)
    #expect(throws: AgentCommandError.invalidArgument("expected alice|bob")) {
      try launching.command(named: "login-as")?.makeAction("carol")
    }
    #expect(throws: AgentCommandError.notApplicable("nothing to go back to on launching")) {
      try launching.command(named: "back")?.makeAction(nil)
    }

    var auth = AuthFlow.State()
    auth.path.append(.register(.init()))
    let pushed = AppFeature.activeScreen(.auth(auth))
    #expect(pushed.path == "auth/register")
    #expect(pushed.command(named: "back")?.source == "AuthFlow")
  }

  @Test func registryCoversEveryScreen() {
    #expect(
      AppFeature.registry.map(\.path) == [
        "launching", "auth/login", "auth/otp/email", "auth/otp/code", "auth/register", "auth/register/verify",
        "auth/forgot/email", "auth/forgot/reset", "auth/forgot/done",
        "onboarding/welcome", "onboarding/interests", "onboarding/address", "onboarding/notifications",
        "home/shop", "home/shop/<sku>", "home/cart", "home/cart/checkout", "home/cart/confirmation",
        "home/orders", "home/orders/<id>", "home/profile",
      ]
    )
    #expect(AppFeature.registry.allSatisfy { doc in doc.commands.contains { $0.name == "login-as" } })
  }
}
