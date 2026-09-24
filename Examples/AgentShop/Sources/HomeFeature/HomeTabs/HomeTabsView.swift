import ComposableArchitecture
import SwiftUI

public struct HomeTabsView: View {
  @Bindable var store: StoreOf<HomeTabs>

  public init(store: StoreOf<HomeTabs>) {
    self.store = store
  }

  public var body: some View {
    TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
      Tab("Orders", systemImage: "bag", value: HomeTabs.Tab.orders) {
        NavigationStack(path: $store.scope(state: \.ordersPath, action: \.ordersPath)) {
          OrdersListView(store: store.scope(state: \.ordersList, action: \.ordersList))
        } destination: { store in
          switch store.case {
          case let .detail(store):
            OrderDetailView(store: store)
          }
        }
      }
      Tab("Profile", systemImage: "person", value: HomeTabs.Tab.profile) {
        NavigationStack {
          ProfileView(store: store.scope(state: \.profile, action: \.profile))
        }
      }
    }
  }
}
