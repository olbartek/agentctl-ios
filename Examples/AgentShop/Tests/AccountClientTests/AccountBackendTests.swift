import AccountClient
import Models
import Testing

struct AccountBackendTests {
  @Test func seededAccountsAreOnboarded() async {
    let backend = AccountBackend()
    let alice = await backend.profile(for: "alice@example.com")
    #expect(!alice.needsOnboarding)
    #expect(alice.address == MockProfiles.aliceAddress)
    #expect(!(await backend.profile(for: "bob@example.com")).needsOnboarding)
  }

  @Test func unknownAccountsNeedOnboardingUntilTheyComplete() async {
    let backend = AccountBackend()
    #expect(await backend.profile(for: "nina@example.com").needsOnboarding)
    let address = Address(name: "Nina", street: "2 Elm St", city: "Portland", zip: "97201")
    let answers = OnboardingAnswers(interests: [.bags, .home], address: address, notifications: true)
    let saved = await backend.completeOnboarding(answers, for: "nina@example.com")
    #expect(saved == AccountProfile(needsOnboarding: false, interests: [.bags, .home], address: address))
    #expect(await backend.profile(for: "nina@example.com") == saved)
  }
}

struct ValidationShopTests {
  @Test(arguments: ["10001", "97201"]) func validZips(_ zip: String) { #expect(isValidZip(zip)) }
  @Test(arguments: ["", "1000", "100011", "1000a", "１２３４５"]) func invalidZips(_ zip: String) { #expect(!isValidZip(zip)) }
  @Test func cardNumbers() {
    #expect(isValidCardNumber("4242 4242 4242 4242"))
    #expect(isValidCardNumber("4000000000000002"))
    #expect(!isValidCardNumber("4242"))
    #expect(!isValidCardNumber("4242-4242-4242-4242"))
  }
}
