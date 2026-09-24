import ComposableArchitecture
import DesignSystem
import SwiftUI

/// Login with an emailed one-time code, in the style of the Figma "Verify Email" frame.
public struct OTPLoginView: View {
  @Bindable var store: StoreOf<OTPLogin>

  public init(store: StoreOf<OTPLogin>) {
    self.store = store
  }

  public var body: some View {
    FormScreen {
      switch store.step {
      case .email:
        ScreenHeader(
          "Login with a Code",
          style: .leading(subtitle: "Enter the email address of your account. We’ll email you a 6-digit code to log in.")
        ) {
          store.send(.backTapped)
        }
        FormField("Email Address", error: store.error?.message) {
          ASTextField("name@example.com", text: $store.email, kind: .email, identifier: "otp.email")
        }
        .padding(.top, 64)
        PrimaryButton("Send Code", isLoading: store.isLoading, isEnabled: store.canSend, identifier: "otp.send") {
          store.send(.sendTapped)
        }
        .padding(.top, Metrics.sectionSpacing)
        PromptLink(
          "Prefer a password?",
          link: "Login with password",
          promptColor: Palette.textSecondary,
          linkFont: Typography.body,
          identifier: "otp.password"
        ) {
          store.send(.backTapped)
        }
        .padding(.top, Metrics.sectionSpacing)

      case .code:
        ScreenHeader(
          "Check your email",
          style: .leading(subtitle: "We’ve sent a 6-digit code to \(store.email). It expires in 5 minutes.")
        ) {
          store.send(.backTapped)
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("Enter Code")
            .font(Typography.sectionLabel)
            .foregroundStyle(Palette.textSubtle)
          CodeInputField(code: $store.code, identifier: "otp.code")
          if let error = store.error {
            InlineError(error.message)
          }
          if store.attemptsLeft == 0 {
            InlineError("Too many wrong codes. Request a new one.")
          }
        }
        .padding(.top, 64)
        PrimaryButton("Login", isLoading: store.isLoading, isEnabled: store.canVerify, identifier: "otp.verify") {
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
          identifier: "otp.resend"
        ) {
          store.send(.resendTapped)
        }
        .padding(.top, Metrics.sectionSpacing)
      }
    }
  }
}

#Preview {
  NavigationStack {
    OTPLoginView(
      store: Store(initialState: OTPLogin.State(step: .code, email: "alice@example.com", resendIn: 12)) { OTPLogin() }
    )
  }
}
