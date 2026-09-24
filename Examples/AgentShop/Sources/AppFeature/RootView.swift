import AuthFeature
import ComposableArchitecture
import DesignSystem
import HomeFeature
import SwiftUI

public struct RootView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    switch store.state {
    case .launching:
      LoadingView("Starting…")
        .task { store.send(.appeared) }
    case .auth:
      if let store = store.scope(state: \.auth, action: \.auth) {
        AuthFlowView(store: store)
      }
    case let .home(home):
      if let store = store.scope(state: \.home, action: \.home) {
        // A new home id (a new sign-in) rebuilds the tabs, so their screens appear afresh.
        HomeTabsView(store: store)
          .id(home.id)
      }
    }
  }
}
