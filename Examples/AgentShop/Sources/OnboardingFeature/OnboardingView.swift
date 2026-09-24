import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

/// Onboarding's four steps, one at a time, with a back button from interests on.
public struct OnboardingView: View {
  let store: StoreOf<OnboardingFlow>

  public init(store: StoreOf<OnboardingFlow>) {
    self.store = store
  }

  public var body: some View {
    Group {
      switch store.step {
      case .welcome:
        WelcomeView(store: store.scope(state: \.welcome, action: \.welcome))
      case .interests:
        InterestsView(store: store.scope(state: \.interests, action: \.interests)) { store.send(.backTapped) }
      case .address:
        AddressFormView(store: store.scope(state: \.address, action: \.address)) { store.send(.backTapped) }
      case .notifications:
        NotificationsView(store: store.scope(state: \.notifications, action: \.notifications)) {
          store.send(.backTapped)
        }
      }
    }
    .animation(.default, value: store.step)
  }
}

struct WelcomeView: View {
  let store: StoreOf<Welcome>

  static let pages: [(symbol: String, title: String, text: String)] = [
    ("bag", "Welcome to AgentShop", "Shoes, bags, watches and more, picked for you."),
    ("heart", "Save what you love", "Favorite products and find them again in a tap."),
    ("shippingbox", "Fast checkout", "Your address is remembered, so an order takes seconds."),
  ]

  var body: some View {
    let page = Self.pages[min(store.page, Self.pages.count) - 1]
    FormScreen {
      HStack {
        if store.page > 1 {
          BackButton(identifier: "Welcome.back") { store.send(.backTapped) }
        }
        Spacer()
        LinkButton("Skip", identifier: "Welcome.skip") { store.send(.skipTapped) }
      }
      .frame(height: 40)

      Image(systemName: page.symbol)
        .font(.system(size: 72))
        .foregroundStyle(Palette.brand)
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
      Text(page.title)
        .font(Typography.screenTitle)
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
      Text(page.text)
        .font(Typography.body)
        .foregroundStyle(Palette.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
      Text(verbatim: "\(store.page) of \(Welcome.pageCount)")
        .font(Typography.caption)
        .foregroundStyle(Palette.textSubtle)
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .summaryValue("Welcome.page", "\(store.page)")
      PrimaryButton(store.page < Welcome.pageCount ? "Next" : "Get started", identifier: "Welcome.next") {
        store.send(.nextTapped)
      }
      .padding(.top, 48)
    }
    .screenIdentifier(Welcome.screenPath(store.state))
  }
}

struct InterestsView: View {
  let store: StoreOf<Interests>
  let onBack: () -> Void

  var body: some View {
    FormScreen {
      ScreenHeader(
        "What do you like?",
        style: .leading(subtitle: "Pick \(Interests.minimum) to \(Interests.maximum) categories for your feed."),
        onBack: onBack
      )
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(ProductCategory.allCases, id: \.self) { category in
          let isOn = store.selected.contains(category)
          Button {
            store.send(.toggled(category))
          } label: {
            Text(category.rawValue.capitalized)
              .font(Typography.bodyMedium)
              .foregroundStyle(isOn ? Palette.onBrand : Palette.textPrimary)
              .frame(maxWidth: .infinity)
              .frame(height: 48)
              .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Palette.brand : Palette.surfaceTint))
          }
          .buttonStyle(.plain)
          .accessibilityValue(isOn ? "on" : "off")
          .accessibilityIdentifier("Interests.toggle.\(category.rawValue)")
        }
      }
      .padding(.top, 40)
      Text(verbatim: "\(store.selected.count) selected")
        .font(Typography.caption)
        .foregroundStyle(Palette.textSubtle)
        .padding(.top, 16)
        .summaryValue("Interests.selected", "\(store.selected.count)")
      if let error = store.error {
        InlineError("Pick at most \(Interests.maximum) categories.", code: error.rawValue)
          .padding(.top, 8)
      }
      PrimaryButton("Continue", isEnabled: store.canContinue, identifier: "Interests.continue") {
        store.send(.continueTapped)
      }
      .padding(.top, Metrics.sectionSpacing)
    }
    .screenIdentifier(Interests.screenPath(store.state))
  }
}

struct AddressFormView: View {
  @Bindable var store: StoreOf<AddressForm>
  let onBack: () -> Void

  var body: some View {
    FormScreen {
      ScreenHeader(
        "Where should we ship?",
        style: .leading(subtitle: "Saved for checkout. You can skip this and add it later."),
        onBack: onBack
      )
      VStack(spacing: Metrics.fieldSpacing) {
        FormField("Full Name") {
          ASTextField("Your name", text: $store.address.name, kind: .name, identifier: "AddressForm.name")
        }
        FormField("Street") {
          ASTextField("1 Main St", text: $store.address.street, identifier: "AddressForm.street")
        }
        FormField("City") {
          ASTextField("City", text: $store.address.city, identifier: "AddressForm.city")
        }
        FormField(
          "Zip Code",
          error: store.error.map { _ in "Enter a five-digit zip code." },
          errorCode: store.error?.rawValue
        ) {
          ASTextField("12345", text: $store.address.zip, identifier: "AddressForm.zip")
        }
      }
      .padding(.top, Metrics.sectionSpacing)
      PrimaryButton("Continue", isEnabled: store.canContinue, identifier: "AddressForm.continue") {
        store.send(.continueTapped)
      }
      .padding(.top, Metrics.sectionSpacing)
      LinkButton("Skip for now", identifier: "AddressForm.skip") { store.send(.skipTapped) }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
    .screenIdentifier(AddressForm.screenPath(store.state))
  }
}

struct NotificationsView: View {
  let store: StoreOf<Notifications>
  let onBack: () -> Void

  var body: some View {
    FormScreen {
      ScreenHeader(
        "Stay in the loop",
        style: .leading(subtitle: "Get a notification when an order ships or a favorite goes on sale."),
        onBack: onBack
      )
      Image(systemName: "bell.badge")
        .font(.system(size: 72))
        .foregroundStyle(Palette.brand)
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
      Text(verbatim: store.choice.map { $0 == .allowed ? "Notifications on" : "Notifications off" } ?? "Not decided yet")
        .font(Typography.caption)
        .foregroundStyle(Palette.textSubtle)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .summaryValue("Notifications.notifications", store.choice?.rawValue ?? "undecided")
      if let error = store.error {
        InlineError(error.message, code: error.rawValue)
          .padding(.top, 16)
        PrimaryButton("Try again", isLoading: store.isLoading, identifier: "Notifications.retry") {
          store.send(.retryTapped)
        }
        .padding(.top, 16)
      }
      PrimaryButton("Allow notifications", isLoading: store.isLoading, identifier: "Notifications.allow") {
        store.send(.chose(.allowed))
      }
      .padding(.top, Metrics.sectionSpacing)
      LinkButton("Not now", identifier: "Notifications.not-now") { store.send(.chose(.off)) }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
    .screenIdentifier(Notifications.screenPath(store.state))
  }
}
