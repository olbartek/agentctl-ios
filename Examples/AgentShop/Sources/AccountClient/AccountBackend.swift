import ComposableArchitecture
import Models

/// The in-memory account server behind ``AccountClient``'s `liveValue`, keyed by the owner's email.
///
/// The seeded accounts Alice, Bob and Locked are already onboarded, and Alice has a saved address. Every other
/// account — Nina (`nina@example.com`), anyone who registers, and the Google account — goes through onboarding
/// once, and the answers are kept here.
public actor AccountBackend {
  private var profiles: [String: AccountProfile]

  public init(seed: [String: AccountProfile] = MockProfiles.seed) {
    self.profiles = seed
  }

  public func profile(for email: String) -> AccountProfile {
    profiles[email] ?? AccountProfile(needsOnboarding: true)
  }

  public func completeOnboarding(_ answers: OnboardingAnswers, for email: String) -> AccountProfile {
    let profile = AccountProfile(needsOnboarding: false, interests: answers.interests, address: answers.address)
    profiles[email] = profile
    return profile
  }
}

public enum MockProfiles {
  public static let aliceAddress = Address(name: "Alice Liddell", street: "1 Rabbit Hole Ln", city: "Oxford", zip: "10001")

  public static let seed: [String: AccountProfile] = [
    "alice@example.com": AccountProfile(needsOnboarding: false, interests: [.shoes, .watches], address: aliceAddress),
    "bob@example.com": AccountProfile(needsOnboarding: false),
    "locked@example.com": AccountProfile(needsOnboarding: false),
  ]
}

public enum AccountBackendKey: DependencyKey {
  public static let liveValue = AccountBackend()
  public static var testValue: AccountBackend {
    reportIssue("AccountBackend is not overridden. Construct one explicitly in the test.")
    return AccountBackend()
  }
  public static var previewValue: AccountBackend { AccountBackend() }
}

extension DependencyValues {
  public var accountBackend: AccountBackend {
    get { self[AccountBackendKey.self] }
    set { self[AccountBackendKey.self] = newValue }
  }
}
