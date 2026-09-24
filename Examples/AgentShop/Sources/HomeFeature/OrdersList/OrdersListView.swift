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
      .navigationTitle("Orders")
      .task { store.send(.onAppear) }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case .loading:
      LoadingView("Loading orders…")
    case .failed:
      ErrorView(store.error?.message ?? "") { store.send(.retry) }
    case .empty:
      EmptyStateView("No orders yet", message: "Orders you place will show up here.", systemImage: "bag")
    case .loaded:
      List {
        if let error = store.error {
          InlineError(error.message)
        }
        ForEach(store.orders) { order in
          Button {
            store.send(.orderTapped(order.id))
          } label: {
            OrderRow(order: order)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("orders.row.\(order.id)")
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
