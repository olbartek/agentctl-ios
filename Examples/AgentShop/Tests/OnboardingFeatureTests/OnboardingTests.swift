import AccountClient
import ComposableArchitecture
import Models
import OnboardingFeature
import Testing

@MainActor
@Suite(.serialized)
struct WelcomeTests {
  @Test func pagesThenFinish() async {
    let store = TestStore(initialState: Welcome.State()) { Welcome() }
    await store.send(.backTapped)
    await store.send(.nextTapped) { $0.page = 2 }
    await store.send(.backTapped) { $0.page = 1 }
    await store.send(.nextTapped) { $0.page = 2 }
    await store.send(.nextTapped) { $0.page = 3 }
    await store.send(.nextTapped)
    await store.receive(\.delegate.finished)
  }

  @Test func skip() async {
    let store = TestStore(initialState: Welcome.State()) { Welcome() }
    await store.send(.skipTapped)
    await store.receive(\.delegate.finished)
  }
}

@MainActor
@Suite(.serialized)
struct InterestsTests {
  @Test func twoToFour() async {
    let store = TestStore(initialState: Interests.State()) { Interests() }
    await store.send(.continueTapped)
    await store.send(.toggled(.shoes)) { $0.selected = [.shoes] }
    #expect(!store.state.canContinue)
    await store.send(.toggled(.bags)) { $0.selected = [.shoes, .bags] }
    await store.send(.toggled(.home)) { $0.selected = [.shoes, .bags, .home] }
    await store.send(.toggled(.watches)) { $0.selected = [.shoes, .bags, .home, .watches] }
    await store.send(.toggled(.jackets)) { $0.error = .tooMany }
    await store.send(.toggled(.home)) {
      $0.selected = [.shoes, .bags, .watches]
      $0.error = nil
    }
    await store.send(.continueTapped)
    await store.receive(\.delegate.chose, [.shoes, .bags, .watches])
  }
}

@MainActor
@Suite(.serialized)
struct AddressFormTests {
  @Test func zipIsValidatedOnContinue() async {
    let store = TestStore(
      initialState: AddressForm.State(address: Address(name: "Nina", street: "2 Elm St", city: "Portland", zip: "972"))
    ) { AddressForm() }
    await store.send(.continueTapped) { $0.error = .invalidZip }
    await store.send(.binding(.set(\.address.zip, "97201"))) {
      $0.address.zip = "97201"
      $0.error = nil
    }
    await store.send(.continueTapped)
    await store.receive(\.delegate.finished)
  }

  @Test func incompleteCannotContinueButCanSkip() async {
    let store = TestStore(initialState: AddressForm.State(address: Address(name: "Nina"))) { AddressForm() }
    #expect(!store.state.canContinue)
    await store.send(.continueTapped)
    await store.send(.skipTapped)
    await store.receive(\.delegate.finished, nil)
  }
}

@MainActor
@Suite(.serialized)
struct NotificationsTests {
  @Test func failureThenRetrySavesTheSameAnswers() async {
    let calls = LockIsolated<[OnboardingAnswers]>([])
    let profile = AccountProfile(needsOnboarding: false, interests: [.bags, .home])
    let store = TestStore(initialState: Notifications.State(interests: [.bags, .home])) {
      Notifications()
    } withDependencies: {
      $0.accountClient.completeOnboarding = { answers in
        calls.withValue { $0.append(answers) }
        if calls.value.count == 1 { throw AccountError.network }
        return profile
      }
    }
    await store.send(.chose(.off)) {
      $0.choice = .off
      $0.isLoading = true
    }
    await store.receive(\.completed.failure) {
      $0.isLoading = false
      $0.error = .network
    }
    await store.send(.retryTapped) {
      $0.isLoading = true
      $0.error = nil
    }
    await store.receive(\.completed.success) { $0.isLoading = false }
    await store.receive(\.delegate.finished, profile)
    #expect(calls.value == Array(repeating: OnboardingAnswers(interests: [.bags, .home], address: nil, notifications: false), count: 2))
  }
}

@MainActor
@Suite(.serialized)
struct OnboardingFlowTests {
  let session = Session(user: User(id: "u4", name: "Nina", email: "nina@example.com"), token: "t")

  @Test func stepsCarryAnswersForward() async {
    let address = Address(name: "Nina", street: "2 Elm St", city: "Portland", zip: "97201")
    let store = TestStore(initialState: OnboardingFlow.State(session: session)) { OnboardingFlow() }
    store.exhaustivity = .off
    await store.send(.welcome(.skipTapped))
    await store.receive(\.welcome.delegate.finished) { $0.step = .interests }
    await store.send(.interests(.toggled(.bags)))
    await store.send(.interests(.toggled(.home)))
    await store.send(.interests(.continueTapped))
    await store.receive(\.interests.delegate.chose) {
      $0.step = .address
      $0.notifications.interests = [.bags, .home]
    }
    await store.send(.backTapped) { $0.step = .interests }
    #expect(store.state.interests.selected == [.bags, .home])
    await store.send(.interests(.continueTapped))
    await store.receive(\.interests.delegate.chose) { $0.step = .address }
    await store.send(.address(.binding(.set(\.address, address))))
    await store.send(.address(.continueTapped))
    await store.receive(\.address.delegate.finished) {
      $0.step = .notifications
      $0.notifications.address = address
    }
  }
}
