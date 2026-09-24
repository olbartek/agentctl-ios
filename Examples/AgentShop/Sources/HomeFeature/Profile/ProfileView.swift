import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

public struct ProfileView: View {
  @Bindable var store: StoreOf<Profile>

  public init(store: StoreOf<Profile>) {
    self.store = store
  }

  public var body: some View {
    List {
      Section {
        LabeledContent("Name", value: store.user.name)
          .accessibilityIdentifier("profile.name")
        LabeledContent("Email", value: store.user.email)
          .accessibilityIdentifier("profile.email")
      }
      Section {
        Button("Log out", role: .destructive) {
          store.send(.logoutTapped)
        }
        .accessibilityIdentifier("profile.logout")
      }
    }
    .navigationTitle("Profile")
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

#Preview {
  NavigationStack {
    ProfileView(
      store: Store(initialState: Profile.State(user: User(id: "u1", name: "Alice", email: "alice@example.com"))) {
        Profile()
      }
    )
  }
}
