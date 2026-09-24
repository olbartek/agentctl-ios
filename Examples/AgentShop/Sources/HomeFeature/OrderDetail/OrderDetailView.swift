import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

public struct OrderDetailView: View {
  let store: StoreOf<OrderDetail>

  public init(store: StoreOf<OrderDetail>) {
    self.store = store
  }

  public var body: some View {
    content
      .navigationTitle(Text(verbatim: "Order #\(store.orderID)"))
      .inlineNavigationTitle()
      .screenIdentifier(OrderDetail.screenPath(store.state))
      .task { store.send(.onAppear) }
  }

  @ViewBuilder
  private var content: some View {
    if let order = store.order {
      List {
        Section {
          LabeledContent("Status", value: order.status.rawValue.capitalized)
            .summaryValue("OrderDetail.status", order.status.rawValue)
          LabeledContent("Placed on", value: formatDay(order.placedOn))
        }
        Section("Items") {
          ForEach(order.items, id: \.name) { item in
            LabeledContent("\(item.name) × \(item.quantity)", value: formatCents(item.totalCents))
          }
          LabeledContent("Total", value: formatCents(order.totalCents))
            .font(.headline)
            .summaryValue("OrderDetail.total", formatCents(order.totalCents))
        }
        if let error = store.error {
          InlineError(error.message, code: error.rawValue)
        }
        if order.isCancellable {
          Section {
            PrimaryButton(
              "Cancel order",
              isLoading: store.isCancelling,
              isEnabled: store.canCancel,
              identifier: "OrderDetail.cancel"
            ) {
              store.send(.cancelTapped)
            }
          }
        }
      }
    } else if let error = store.error {
      ErrorView(error.message, code: error.rawValue, retryIdentifier: "OrderDetail.retry") { store.send(.retry) }
    } else {
      LoadingView("Loading order…")
    }
  }
}

#Preview {
  NavigationStack {
    OrderDetailView(store: Store(initialState: OrderDetail.State(orderID: 1003)) { OrderDetail() })
  }
}
