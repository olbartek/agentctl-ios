import CatalogClient
import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

// The shop's screens. Identifiers follow DesignSystem/UITestIdentifiers.swift: `<Screen>.<command>` for what a
// command taps or types into, `<Screen>.<command>.<argument>` for a choice, `<Screen>.<key>` for a shown value.

public struct ShopFeedView: View {
  @Bindable var store: StoreOf<ShopFeed>

  public init(store: StoreOf<ShopFeed>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(Palette.textSecondary)
          TextField("Search products", text: $store.query)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .accessibilityIdentifier("ShopFeed.search")
          if !store.query.isEmpty {
            Button("Clear", systemImage: "xmark.circle.fill") { store.send(.clearSearchTapped) }
              .labelStyle(.iconOnly)
              .foregroundStyle(Palette.textSecondary)
              .accessibilityIdentifier("ShopFeed.clear-search")
          }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surfaceTint))

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            chip("All", isOn: store.filter == nil, id: "ShopFeed.filter.all") { store.send(.filterTapped(nil)) }
            ForEach(ProductCategory.allCases, id: \.self) { category in
              chip(category.rawValue.capitalized, isOn: store.filter == category, id: "ShopFeed.filter.\(category.rawValue)") {
                store.send(.filterTapped(category))
              }
            }
          }
        }
        .summaryValue("ShopFeed.filter", store.filter?.rawValue ?? "all")

        HStack(spacing: 8) {
          Text(verbatim: "\(store.visible.count) products")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSubtle)
            .summaryValue("ShopFeed.products", "\(store.visible.count)")
          Spacer()
          ForEach(ShopFeed.Sort.allCases, id: \.self) { sort in
            chip(sortLabel(sort), isOn: store.sort == sort, id: "ShopFeed.sort.\(sort.rawValue)") {
              store.send(.sortTapped(sort))
            }
          }
        }
        .accessibilityElement(children: .contain)
        .summaryValue("ShopFeed.sort", store.sort.rawValue)

        if let error = store.error {
          if store.products.isEmpty {
            ErrorView(error.message, code: error.rawValue, retryIdentifier: "ShopFeed.retry") { store.send(.retry) }
          } else {
            InlineError(error.message, code: error.rawValue)
            Button("Try again") { store.send(.retry) }
              .accessibilityIdentifier("ShopFeed.retry")
          }
        } else if store.isLoading, store.products.isEmpty {
          LoadingView("Loading products…").frame(height: 200)
        }

        // Not lazy: twelve rows, and every one exists for UI tests to find without scrolling first.
        VStack(spacing: 0) {
          ForEach(store.visible) { product in
            Button {
              store.send(.productTapped(product.id))
            } label: {
              ProductRow(product: product)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ShopFeed.open.\(product.id)")
            Divider()
          }
        }
      }
      .padding(.horizontal)
    }
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { store.send(.refresh) }
        .accessibilityIdentifier("ShopFeed.refresh")
    }
    .navigationTitle("Shop")
    .screenIdentifier(ShopFeed.screenPath(store.state))
    .task { store.send(.onAppear) }
  }

  private func sortLabel(_ sort: ShopFeed.Sort) -> String {
    switch sort {
    case .featured: "Featured"
    case .priceAsc: "Price ↑"
    case .priceDesc: "Price ↓"
    }
  }

  private func chip(_ title: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(Typography.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isOn ? Palette.onBrand : Palette.textPrimary)
        .background(Capsule().fill(isOn ? Palette.brand : Palette.surfaceTint))
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOn ? "on" : "off")
    .accessibilityIdentifier(id)
  }
}

struct ProductRow: View {
  let product: Product

  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Palette.surfaceTint)
        .frame(width: 56, height: 56)
        .overlay(Image(systemName: product.category.symbol).foregroundStyle(Palette.brand))
      VStack(alignment: .leading, spacing: 4) {
        Text(product.name).font(Typography.bodyMedium).foregroundStyle(Palette.textPrimary)
        Text(product.inStock ? product.category.rawValue.capitalized : "Out of stock")
          .font(Typography.caption)
          .foregroundStyle(product.inStock ? Palette.textSecondary : Palette.error)
      }
      Spacer()
      Text(formatCents(product.priceCents)).font(Typography.bodyMedium).foregroundStyle(Palette.textPrimary)
    }
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

extension ProductCategory {
  var symbol: String {
    switch self {
    case .shoes: "shoeprints.fill"
    case .bags: "bag.fill"
    case .watches: "applewatch"
    case .jackets: "tshirt.fill"
    case .accessories: "eyeglasses"
    case .home: "cup.and.saucer.fill"
    }
  }
}

public struct ProductDetailView: View {
  let store: StoreOf<ProductDetail>

  public init(store: StoreOf<ProductDetail>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        RoundedRectangle(cornerRadius: 16)
          .fill(Palette.surfaceTint)
          .frame(height: 180)
          .overlay(Image(systemName: store.product.category.symbol).font(.system(size: 56)).foregroundStyle(Palette.brand))
        HStack(alignment: .firstTextBaseline) {
          Text(store.product.name)
            .font(Typography.screenTitle)
            .summaryValue("ProductDetail.name", store.product.name)
          Spacer()
          Button {
            store.send(.favoriteToggled(!store.isFavorite))
          } label: {
            Image(systemName: store.isFavorite ? "heart.fill" : "heart").font(.title2)
          }
          .accessibilityLabel("Favorite")
          .accessibilityValue(store.isFavorite ? "on" : "off")
          .accessibilityIdentifier("ProductDetail.favorite")
        }
        Text(formatCents(store.product.priceCents))
          .font(Typography.sectionLabel)
          .summaryValue("ProductDetail.price", formatCents(store.product.priceCents))
        if !store.product.inStock {
          Text("Out of stock").font(Typography.bodyMedium).foregroundStyle(Palette.error)
        }

        if !store.product.sizes.isEmpty {
          Text("Size").font(Typography.bodyMedium)
          HStack(spacing: 8) {
            ForEach(store.product.sizes, id: \.self) { size in
              let isOn = store.size == size
              Button(size) { store.send(.sizeTapped(size)) }
                .font(Typography.bodyMedium)
                .frame(width: 48, height: 40)
                .foregroundStyle(isOn ? Palette.onBrand : Palette.textPrimary)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Palette.brand : Palette.surfaceTint))
                .buttonStyle(.plain)
                .accessibilityValue(isOn ? "on" : "off")
                .accessibilityIdentifier("ProductDetail.size.\(size)")
            }
          }
          .accessibilityElement(children: .contain)
          .summaryValue("ProductDetail.size", store.size ?? "none")
        }

        HStack(spacing: 16) {
          Text("Quantity").font(Typography.bodyMedium)
          Spacer()
          Button("Fewer", systemImage: "minus.circle") { store.send(.quantityDownTapped) }
            .labelStyle(.iconOnly).font(.title2)
            .accessibilityIdentifier("ProductDetail.qty-down")
          Text(verbatim: "\(store.quantity)")
            .font(Typography.sectionLabel)
            .frame(minWidth: 24)
            .summaryValue("ProductDetail.qty", "\(store.quantity)")
          Button("More", systemImage: "plus.circle") { store.send(.quantityUpTapped) }
            .labelStyle(.iconOnly).font(.title2)
            .accessibilityIdentifier("ProductDetail.qty-up")
        }
        if let error = store.error {
          InlineError(
            error == .maxQuantity ? "At most \(ProductDetail.maxQuantity) per order." : "At least one.",
            code: error.rawValue
          )
        }

        PrimaryButton("Add to cart", isEnabled: store.canAdd, identifier: "ProductDetail.add-to-cart") {
          store.send(.addToCartTapped)
        }
        Text(verbatim: store.added == 0 ? "Not in your cart yet" : "Added \(store.added) to your cart")
          .font(Typography.caption)
          .foregroundStyle(Palette.textSubtle)
          .frame(maxWidth: .infinity)
          .summaryValue("ProductDetail.inCart", "\(store.added)")
        LinkButton("View cart", identifier: "ProductDetail.view-cart") { store.send(.viewCartTapped) }
          .frame(maxWidth: .infinity)
      }
      .padding()
    }
    .navigationTitle(store.product.name)
    .inlineNavigationTitle()
    .screenIdentifier(ProductDetail.screenPath(store.state))
  }
}

public struct CartView: View {
  @Bindable var store: StoreOf<Cart>

  public init(store: StoreOf<Cart>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if store.lines.isEmpty {
          EmptyStateView("Your cart is empty", message: "Products you add show up here.", systemImage: "cart")
            .frame(height: 240)
        }
        ForEach(store.lines) { line in
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
              Text(line.product.name).font(Typography.bodyMedium)
              Text(line.size.map { "Size \($0)" } ?? "One size").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Fewer", systemImage: "minus.circle") { store.send(.decrementTapped(line.id)) }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("Cart.dec.\(line.id)")
            Text(verbatim: "\(line.quantity)").frame(minWidth: 20)
            Button("More", systemImage: "plus.circle") { store.send(.incrementTapped(line.id)) }
              .labelStyle(.iconOnly)
              .accessibilityIdentifier("Cart.inc.\(line.id)")
            Text(formatCents(line.totalCents)).font(Typography.bodyMedium).frame(minWidth: 72, alignment: .trailing)
            Button("Remove", systemImage: "trash") { store.send(.removeTapped(line.id)) }
              .labelStyle(.iconOnly)
              .foregroundStyle(Palette.error)
              .accessibilityIdentifier("Cart.remove.\(line.id)")
          }
          Divider()
        }
        Text(verbatim: store.lines.isEmpty ? "none" : store.lines.map(\.id).joined(separator: ","))
          .font(Typography.caption)
          .foregroundStyle(.clear)
          .frame(height: 1)
          .summaryValue("Cart.lines", store.lines.isEmpty ? "none" : store.lines.map(\.id).joined(separator: ","))

        HStack(spacing: 8) {
          TextField("Promo code", text: $store.promoCode)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .accessibilityIdentifier("Cart.promo")
          Button("Apply") { store.send(.applyPromoTapped) }
            .disabled(!store.canApplyPromo)
            .accessibilityIdentifier("Cart.apply-promo")
        }
        if let promo = store.promo {
          HStack {
            Text("Promo \(promo.code): \(promo.percentOff)% off").font(Typography.caption)
            Spacer()
            Button("Remove promo") { store.send(.clearPromoTapped) }
              .font(Typography.caption)
              .accessibilityIdentifier("Cart.clear-promo")
          }
          .accessibilityElement(children: .contain)
          .summaryValue("Cart.promo", promo.code)
        }
        if let error = store.error {
          InlineError(error == .invalidPromo ? "That code isn't valid." : "The network is unreachable. Try again.", code: error.rawValue)
        }

        VStack(spacing: 6) {
          amountRow("Items", "\(store.itemCount)", id: "Cart.items")
          amountRow("Subtotal", formatCents(store.subtotalCents), id: "Cart.subtotal")
          amountRow("Discount", formatCents(store.discountCents), id: "Cart.discount")
          amountRow("Total", formatCents(store.totalCents), id: "Cart.total").font(Typography.sectionLabel)
        }
        PrimaryButton("Checkout", isEnabled: store.canCheckout, identifier: "Cart.checkout") {
          store.send(.checkoutTapped)
        }
      }
      .padding()
    }
    .navigationTitle("Cart")
    .screenIdentifier(Cart.screenPath(store.state))
  }

  private func amountRow(_ label: String, _ value: String, id: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).summaryValue(id, value)
    }
    .font(Typography.body)
  }
}

public struct CheckoutView: View {
  @Bindable var store: StoreOf<Checkout>

  public init(store: StoreOf<Checkout>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Ship to").font(Typography.sectionLabel)
        ASTextField("Full name", text: $store.address.name, kind: .name, identifier: "Checkout.name")
        ASTextField("Street", text: $store.address.street, identifier: "Checkout.street")
        ASTextField("City", text: $store.address.city, identifier: "Checkout.city")
        ASTextField("Zip code", text: $store.address.zip, identifier: "Checkout.zip")

        Text("Shipping").font(Typography.sectionLabel)
        choiceRow(Checkout.Shipping.allCases, selected: store.shipping, id: "Checkout.shipping", label: {
          $0 == .standard ? "Standard (free)" : "Express (+\(formatCents(Checkout.expressShippingCents)))"
        }) { store.send(.shippingTapped($0)) }

        Text("Payment").font(Typography.sectionLabel)
        choiceRow(Checkout.Payment.allCases, selected: store.payment, id: "Checkout.payment", label: {
          $0 == .card ? "Card" : "Apple Pay"
        }) { store.send(.paymentTapped($0)) }
        if store.payment == .card {
          ASTextField("Card number", text: $store.cardNumber, kind: .oneTimeCode, identifier: "Checkout.card")
        }

        if let error = store.error {
          InlineError(message(error), code: error.rawValue)
        }
        HStack {
          Text("Total")
          Spacer()
          Text(formatCents(store.totalCents)).summaryValue("Checkout.total", formatCents(store.totalCents))
        }
        .font(Typography.sectionLabel)
        PrimaryButton(
          "Place order",
          isLoading: store.isPlacing,
          isEnabled: store.canPlace,
          identifier: "Checkout.place-order"
        ) {
          store.send(.placeOrderTapped)
        }
      }
      .padding()
    }
    .navigationTitle("Checkout")
    .inlineNavigationTitle()
    .screenIdentifier(Checkout.screenPath(store.state))
    .task { store.send(.onAppear) }
  }

  private func message(_ error: Checkout.Error) -> String {
    switch error {
    case .invalidZip: "Enter a five-digit zip code."
    case .invalidCard: "Enter a 16-digit card number."
    case .paymentDeclined: OrdersError.paymentDeclined.message
    case .network: OrdersError.network.message
    }
  }

  private func choiceRow<Choice: RawRepresentable & Hashable>(
    _ choices: [Choice],
    selected: Choice,
    id: String,
    label: @escaping (Choice) -> String,
    action: @escaping (Choice) -> Void
  ) -> some View where Choice.RawValue == String {
    HStack(spacing: 8) {
      ForEach(choices, id: \.self) { choice in
        let isOn = choice == selected
        Button(label(choice)) { action(choice) }
          .font(Typography.bodyMedium)
          .frame(maxWidth: .infinity, minHeight: 40)
          .foregroundStyle(isOn ? Palette.onBrand : Palette.textPrimary)
          .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Palette.brand : Palette.surfaceTint))
          .buttonStyle(.plain)
          .accessibilityValue(isOn ? "on" : "off")
          .accessibilityIdentifier("\(id).\(choice.rawValue)")
      }
    }
    .accessibilityElement(children: .contain)
    .summaryValue(id, selected.rawValue)
  }
}

public struct OrderConfirmationView: View {
  let store: StoreOf<OrderConfirmation>

  public init(store: StoreOf<OrderConfirmation>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(Palette.checkboxOn)
      Text("Thanks for your order!").font(Typography.screenTitle)
      Text(verbatim: "Order #\(store.order.id)")
        .font(Typography.sectionLabel)
        .summaryValue("OrderConfirmation.order", "\(store.order.id)")
      Text(formatCents(store.order.totalCents))
        .summaryValue("OrderConfirmation.total", formatCents(store.order.totalCents))
      PrimaryButton("View order", identifier: "OrderConfirmation.view-order") { store.send(.viewOrderTapped) }
      LinkButton("Continue shopping", identifier: "OrderConfirmation.continue-shopping") {
        store.send(.continueShoppingTapped)
      }
    }
    .padding(28)
    .navigationBarBackButtonHiddenIfAvailable()
    .screenIdentifier(OrderConfirmation.screenPath(store.state))
  }
}

extension View {
  /// The order is placed; there is no going back to checkout.
  func navigationBarBackButtonHiddenIfAvailable() -> some View {
    navigationBarBackButtonHidden(true)
  }
}

extension CatalogError {
  var message: String {
    switch self {
    case .network: "The network is unreachable. Try again."
    case .timeout: "The shop took too long to answer. Try again."
    }
  }
}
