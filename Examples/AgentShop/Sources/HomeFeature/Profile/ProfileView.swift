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
          .summaryValue("Profile.name", store.user.name)
        LabeledContent("Email", value: store.user.email)
          .summaryValue("Profile.email", store.user.email)
      }
      Section {
        Toggle("Order updates", isOn: Binding(get: { store.orderUpdates }, set: { store.send(.orderUpdatesToggled($0)) }))
          .accessibilityIdentifier("Profile.order-updates")
        Toggle("Sign in with Face ID", isOn: Binding(get: { store.faceID }, set: { store.send(.faceIDToggled($0)) }))
          .accessibilityIdentifier("Profile.face-id")
      } footer: {
        if let error = store.error {
          Text(Self.message(for: error))
            .foregroundStyle(.red)
            .accessibilityIdentifier("error:\(error.rawValue)")
        }
      }
      Section {
        Button("Log out", role: .destructive) {
          store.send(.logoutTapped)
        }
        .accessibilityIdentifier("Profile.logout")
      }
    }
    .navigationTitle("Profile")
    .onAppear { store.send(.onAppear) }
    .screenIdentifier(Profile.screenPath(store.state))
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

extension ProfileView {
  static func message(for error: Profile.Error) -> String {
    switch error {
    case .notificationsDenied: "Notifications are off for AgentShop. Turn them on in Settings."
    case .biometryFailed: "Face ID didn't recognize you."
    case .biometryUnavailable: "Face ID isn't set up on this device."
    }
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
