import ComposableArchitecture
import ShopFeature
import SwiftUI

public struct HomeTabsView: View {
  @Bindable var store: StoreOf<HomeTabs>

  public init(store: StoreOf<HomeTabs>) {
    self.store = store
  }

  public var body: some View {
    TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
      Tab("Shop", systemImage: "storefront", value: HomeTabs.Tab.shop) {
        NavigationStack(path: $store.scope(state: \.shopPath, action: \.shopPath)) {
          ShopFeedView(store: store.scope(state: \.shop, action: \.shop))
        } destination: { store in
          switch store.case {
          case let .product(store):
            ProductDetailView(store: store)
          }
        }
      }
      Tab("Cart", systemImage: "cart", value: HomeTabs.Tab.cart) {
        NavigationStack(path: $store.scope(state: \.cartPath, action: \.cartPath)) {
          CartView(store: store.scope(state: \.cart, action: \.cart))
        } destination: { store in
          switch store.case {
          case let .checkout(store):
            CheckoutView(store: store)
          case let .confirmation(store):
            OrderConfirmationView(store: store)
          }
        }
      }
      .badge(store.cart.itemCount)
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
