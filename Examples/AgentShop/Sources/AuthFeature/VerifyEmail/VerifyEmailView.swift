import ComposableArchitecture
import DesignSystem
import SwiftUI

/// The Figma "Verify Email" frame.
public struct VerifyEmailView: View {
  @Bindable var store: StoreOf<VerifyEmail>

  public init(store: StoreOf<VerifyEmail>) {
    self.store = store
  }

  public var body: some View {
    FormScreen {
      ScreenHeader(
        "Please verify your email address",
        style: .leading(subtitle: "We’ve sent an email to \(store.email), please enter the code below.")
      ) {
        store.send(.backTapped)
      }

      VStack(alignment: .leading, spacing: 16) {
        Text("Enter Code")
          .font(Typography.sectionLabel)
          .foregroundStyle(Palette.textSubtle)
        CodeInputField(code: $store.code, identifier: "verify.code")
        if let error = store.error {
          InlineError(error.message)
        }
      }
      .padding(.top, 64)

      PrimaryButton(
        "Create Account",
        isLoading: store.isLoading,
        isEnabled: store.canVerify,
        identifier: "verify.submit"
      ) {
        store.send(.verifyTapped)
      }
      .padding(.top, Metrics.sectionSpacing)

      PromptLink(
        "Didn’t see your email?",
        link: store.resendIn > 0 ? "Resend in \(store.resendIn)s" : "Resend",
        promptColor: Palette.textSecondary,
        linkFont: Typography.bodyMedium,
        underlined: true,
        isEnabled: store.resendIn == 0 && !store.isLoading,
        identifier: "verify.resend"
      ) {
        store.send(.resendTapped)
      }
      .padding(.top, Metrics.sectionSpacing)
    }
    .onAppear { store.send(.onAppear) }
  }
}

#Preview {
  NavigationStack {
    VerifyEmailView(store: Store(initialState: VerifyEmail.State(email: "becca@gmail.com", code: "123")) {
      VerifyEmail()
    })
  }
}
