import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

public struct OrdersListView: View {
  let store: StoreOf<OrdersList>

  public init(store: StoreOf<OrdersList>) {
    self.store = store
  }

  public var body: some View {
    content
      .safeAreaInset(edge: .top) {
        // How many orders there are, in words; UI tests read it as `OrdersList.orders`.
        Text(verbatim: store.orders.count == 1 ? "1 order" : "\(store.orders.count) orders")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .summaryValue("OrdersList.orders", "\(store.orders.count)")
      }
      .toolbar {
        Button("Refresh", systemImage: "arrow.clockwise") { store.send(.refresh) }
          .accessibilityIdentifier("OrdersList.refresh")
      }
      .navigationTitle("Orders")
      .screenIdentifier(OrdersList.screenPath(store.state))
      .task { store.send(.onAppear) }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .loading:
      LoadingView("Loading orders…")
    case .failed:
      ErrorView(store.error?.message ?? "", code: store.error?.rawValue, retryIdentifier: "OrdersList.retry") {
        store.send(.retry)
      }
    case .empty:
      EmptyStateView("No orders yet", message: "Orders you place will show up here.", systemImage: "bag")
    case .loaded:
      List {
        if let error = store.error {
          InlineError(error.message, code: error.rawValue)
          Button("Try again") { store.send(.retry) }
            .accessibilityIdentifier("OrdersList.retry")
        }
        ForEach(store.orders) { order in
          Button {
            store.send(.orderTapped(order.id))
          } label: {
            OrderRow(order: order)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("OrdersList.open.\(order.id)")
        }
      }
      .refreshable { await store.send(.refresh).finish() }
    }
  }
}

struct OrderRow: View {
  let order: Order

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        // `verbatim`: an interpolated Int in a localized string would get grouping separators ("#1.001").
        Text(verbatim: "Order #\(order.id)").font(.headline)
        Text(formatDay(order.placedOn)).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text(formatCents(order.totalCents)).font(.headline)
        Text(order.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.right")
        .font(.footnote)
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }
}

#Preview {
  NavigationStack {
    OrdersListView(store: Store(initialState: OrdersList.State()) { OrdersList() })
  }
}
