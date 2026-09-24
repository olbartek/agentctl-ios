import AccountClient
import AgentCtlCore
import CartClient
import CatalogClient
import ComposableArchitecture
import Models
import OrdersClient
import ShopFeature
import Testing

let trailRunner = Catalog.products[0]  // 101, shoes, $89.00, sizes 40–44
let tote = Catalog.products[2]  // 103, bags, $29.00, one size
let beanie = Catalog.products[8]  // 109, out of stock

@MainActor
@Suite(.serialized)
struct ShopFeedTests {
  @Test func filterSearchAndSort() {
    var state = ShopFeed.State(products: Catalog.products, hasLoaded: true)
    #expect(state.visible.map(\.id) == Array(101...112))
    state.filter = .jackets
    #expect(state.visible.map(\.id) == [107, 108])
    state.filter = nil
    state.query = "  WATCH "
    #expect(state.visible.map(\.id) == [105, 106])
    state.query = ""
    state.sort = .priceAsc
    #expect(state.visible.prefix(3).map(\.id) == [111, 109, 103])
    state.sort = .priceDesc
    #expect(state.visible.prefix(2).map(\.id) == [106, 108])
  }

  @Test func loadsOnceAndRefreshFailureKeepsProducts() async {
    let calls = LockIsolated(0)
    let store = TestStore(initialState: ShopFeed.State()) {
      ShopFeed()
    } withDependencies: {
      $0.catalogClient.fetchProducts = {
        calls.withValue { $0 += 1 }
        if calls.value == 2 { throw CatalogError.timeout }
        return Catalog.products
      }
    }
    await store.send(.onAppear) { $0.isLoading = true }
    await store.receive(\.productsResponse.success) {
      $0.isLoading = false
      $0.hasLoaded = true
      $0.products = Catalog.products
    }
    await store.send(.onAppear)
    await store.send(.refresh) { $0.isLoading = true }
    await store.receive(\.productsResponse.failure) {
      $0.isLoading = false
      $0.error = .timeout
    }
    #expect(store.state.visible.count == 12)
  }

  @Test func openingAProduct() async {
    let store = TestStore(initialState: ShopFeed.State(products: Catalog.products, hasLoaded: true)) { ShopFeed() }
    await store.send(.productTapped(103))
    await store.receive(\.delegate.openProduct, tote)
  }
}

@MainActor
@Suite(.serialized)
struct ProductDetailTests {
  @Test func sizeIsRequiredAndQuantityIsBounded() async {
    let store = TestStore(initialState: ProductDetail.State(product: trailRunner)) { ProductDetail() }
    #expect(!store.state.canAdd)
    await store.send(.addToCartTapped)
    await store.send(.sizeTapped("39"))
    await store.send(.sizeTapped("42")) { $0.size = "42" }
    await store.send(.quantityDownTapped) { $0.error = .minQuantity }
    for quantity in 2...5 {
      await store.send(.quantityUpTapped) {
        $0.quantity = quantity
        $0.error = nil
      }
    }
    await store.send(.quantityUpTapped) { $0.error = .maxQuantity }
    await store.send(.addToCartTapped) {
      $0.added = 5
      $0.error = nil
    }
    await store.receive(\.delegate.add, CartLine(product: trailRunner, size: "42", quantity: 5))
  }

  @Test func outOfStockCannotBeAdded() async {
    let store = TestStore(initialState: ProductDetail.State(product: beanie)) { ProductDetail() }
    #expect(!store.state.canAdd)
    await store.send(.addToCartTapped)
  }
}

@MainActor
@Suite(.serialized)
struct CartTests {
  @Test func linesMergeAndAdjust() async {
    let store = TestStore(initialState: Cart.State()) { Cart() }
    await store.send(.add(CartLine(product: tote, size: nil, quantity: 1))) {
      $0.lines = [CartLine(product: tote, size: nil, quantity: 1)]
    }
    await store.send(.add(CartLine(product: tote, size: nil, quantity: 2))) { $0.lines[id: "103"]?.quantity = 3 }
    await store.send(.add(CartLine(product: trailRunner, size: "42", quantity: 1))) {
      $0.lines.append(CartLine(product: trailRunner, size: "42", quantity: 1))
    }
    #expect(store.state.itemCount == 4)
    #expect(store.state.subtotalCents == 3 * 2900 + 8900)
    await store.send(.decrementTapped("101-42")) { $0.lines.remove(id: "101-42") }
    await store.send(.incrementTapped("103")) { $0.lines[id: "103"]?.quantity = 4 }
    await store.send(.removeTapped("103")) { $0.lines = [] }
    #expect(!store.state.canCheckout)
  }

  @Test func promoValidThenInvalid() async {
    let store = TestStore(initialState: Cart.State(lines: [CartLine(product: trailRunner, size: "42", quantity: 2)])) {
      Cart()
    } withDependencies: {
      $0.cartClient = .liveValue
      $0.mockCallLog = MockCallLog()
      $0.mockFaults = MockFaults()
      $0.mockLatency = .zero
    }
    await store.send(.binding(.set(\.promoCode, "save10"))) { $0.promoCode = "save10" }
    await store.send(.applyPromoTapped) { $0.isApplyingPromo = true }
    await store.receive(\.promoResponse.success) {
      $0.isApplyingPromo = false
      $0.promo = Promo(code: "SAVE10", percentOff: 10)
      $0.promoCode = ""
    }
    #expect(store.state.totalCents == 17800 - 1780)
    await store.send(.binding(.set(\.promoCode, "FREE"))) { $0.promoCode = "FREE" }
    await store.send(.applyPromoTapped) { $0.isApplyingPromo = true }
    await store.receive(\.promoResponse.failure) {
      $0.isApplyingPromo = false
      $0.error = .invalidPromo
    }
    #expect(store.state.promo?.code == "SAVE10")
  }
}

@MainActor
@Suite(.serialized)
struct CheckoutTests {
  let lines = [CartLine(product: tote, size: nil, quantity: 2)]
  let address = Address(name: "Bob", street: "3 Oak Ave", city: "Austin", zip: "73301")

  @Test func prefillsFromTheAccountOnlyWhenUntouched() async {
    let saved = MockProfiles.aliceAddress
    let store = TestStore(initialState: Checkout.State(lines: lines)) {
      Checkout()
    } withDependencies: {
      $0.accountClient.fetchProfile = { AccountProfile(needsOnboarding: false, address: saved) }
    }
    await store.send(.onAppear) { $0.hasLoadedAddress = true }
    await store.receive(\.profileLoaded) { $0.address = saved }
    await store.send(.onAppear)
  }

  @Test func validationThenDeclineThenApplePay() async {
    let placed = LockIsolated<[OrderRequest]>([])
    let order = Order(id: 1001, status: .pending, placedOn: day("2026-01-01"), items: [])
    var start = Checkout.State(lines: lines, address: address)
    start.address.zip = "7330"
    let store = TestStore(initialState: start) {
      Checkout()
    } withDependencies: {
      $0.ordersClient.placeOrder = { request in
        placed.withValue { $0.append(request) }
        if request.cardNumber != nil { throw OrdersError.paymentDeclined }
        return order
      }
    }
    #expect(!store.state.canPlace)
    await store.send(.binding(.set(\.cardNumber, "4242"))) { $0.cardNumber = "4242" }
    await store.send(.placeOrderTapped) { $0.error = .invalidZip }
    await store.send(.binding(.set(\.address.zip, "73301"))) {
      $0.address.zip = "73301"
      $0.error = nil
    }
    await store.send(.placeOrderTapped) { $0.error = .invalidCard }
    await store.send(.binding(.set(\.cardNumber, "4000 0000 0000 0002"))) {
      $0.cardNumber = "4000 0000 0000 0002"
      $0.error = nil
    }
    await store.send(.shippingTapped(.express)) { $0.shipping = .express }
    #expect(store.state.totalCents == 2 * 2900 + 1500)
    await store.send(.placeOrderTapped) { $0.isPlacing = true }
    await store.receive(\.placed.failure) {
      $0.isPlacing = false
      $0.error = .paymentDeclined
    }
    await store.send(.paymentTapped(.applePay)) {
      $0.payment = .applePay
      $0.error = nil
    }
    await store.send(.placeOrderTapped) { $0.isPlacing = true }
    await store.receive(\.placed.success) { $0.isPlacing = false }
    await store.receive(\.delegate.placed, order)
    #expect(placed.value.map(\.cardNumber) == ["4000 0000 0000 0002", nil])
    #expect(placed.value.last?.shippingCents == 1500)
  }
}

struct OrdersBackendPlaceTests {
  @Test func placedOrdersGetTheNextIDAndCarryShippingAndDiscount() async throws {
    let backend = OrdersBackend()
    let request = OrderRequest(
      lines: [CartLine(product: trailRunner, size: "42", quantity: 2)],
      address: MockProfiles.aliceAddress,
      shippingCents: 1500,
      discountCents: 1780,
      cardNumber: "4242 4242 4242 4242"
    )
    let order = try await backend.placeOrder(request, for: "alice@example.com", on: day("2026-01-01"))
    #expect(order.id == 1004)
    #expect(order.items.map(\.name) == ["Trail Runner (42)", "Express shipping", "Promo discount"])
    #expect(formatCents(order.totalCents) == "$175.20")
    #expect(try await backend.placeOrder(request, for: "bob@example.com", on: day("2026-01-01")).id == 1001)
    var declined = request
    declined.cardNumber = "4000 0000 0000 0002"
    await #expect(throws: OrdersError.paymentDeclined) {
      try await backend.placeOrder(declined, for: "alice@example.com", on: day("2026-01-01"))
    }
  }
}
