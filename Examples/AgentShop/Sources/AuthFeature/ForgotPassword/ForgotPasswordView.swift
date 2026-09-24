import ComposableArchitecture
import DesignSystem
import SwiftUI

/// The Figma "Forgot Password" frame (the email step), and the reset and done steps in the same style.
public struct ForgotPasswordView: View {
  @Bindable var store: StoreOf<ForgotPassword>

  public init(store: StoreOf<ForgotPassword>) {
    self.store = store
  }

  public var body: some View {
    FormScreen {
      switch store.step {
      case .email:
        ScreenHeader(
          "Forgot Password",
          style: .leading(
            subtitle: "Enter the email address registered with your account. We’ll send you a code to reset your password."
          )
        ) {
          store.send(.backTapped)
        }
        FormField("Email Address", error: store.error?.message, errorCode: store.error?.rawValue) {
          ASTextField("name@example.com", text: $store.email, kind: .email, identifier: "ForgotPassword.email")
        }
        .padding(.top, 64)
        PrimaryButton("Submit", isLoading: store.isLoading, isEnabled: store.canSend, identifier: "ForgotPassword.send") {
          store.send(.sendTapped)
        }
        .padding(.top, Metrics.sectionSpacing)
        loginLink

      case .reset:
        ScreenHeader(
          "Reset Password",
          style: .leading(subtitle: "If \(store.email) has an account, we’ve sent it a 6-digit code. Enter it with your new password.")
        ) {
          store.send(.backTapped)
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("Enter Code")
            .font(Typography.sectionLabel)
            .foregroundStyle(Palette.textSubtle)
          CodeInputField(code: $store.code, identifier: "ForgotPassword.code")
        }
        .padding(.top, 64)
        VStack(spacing: Metrics.fieldSpacing) {
          FormField("New Password", error: store.passwordFieldIssues.message) {
            ASSecureField(
              text: $store.password,
              isRevealed: $store.showPassword,
              kind: .newPassword,
              identifier: "ForgotPassword.password",
              revealIdentifier: "ForgotPassword.show-password"
            )
          }
          FormField("Confirm Password", error: store.confirmFieldIssues.message) {
            ASSecureField(
              text: $store.confirm,
              isRevealed: $store.showConfirm,
              kind: .newPassword,
              identifier: "ForgotPassword.confirm",
              revealIdentifier: "ForgotPassword.show-confirm"
            )
          }
        }
        .padding(.top, Metrics.fieldSpacing)
        if let error = store.error {
          InlineError(error.message, code: error.rawValue)
            .padding(.top, 16)
        }
        PrimaryButton(
          "Reset Password",
          isLoading: store.isLoading,
          isEnabled: store.canSubmit,
          identifier: "ForgotPassword.submit"
        ) {
          store.send(.submitTapped)
        }
        .padding(.top, Metrics.sectionSpacing)
        loginLink

      case .done:
        ScreenHeader(
          "Password Changed",
          style: .leading(subtitle: "Your password has been reset. Log in with your new password.")
        ) {
          store.send(.backTapped)
        }
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(Palette.checkboxOn)
          .frame(maxWidth: .infinity)
          .padding(.top, 64)
        PrimaryButton("Back to Login", identifier: "ForgotPassword.to-login") {
          store.send(.backToLoginTapped)
        }
        .padding(.top, 64)
      }
    }
    .screenIdentifier(ForgotPassword.screenPath(store.state))
  }

  private var loginLink: some View {
    PromptLink(
      "Remembered password?",
      link: "Login to your account",
      promptColor: Palette.textSecondary,
      linkFont: Typography.body,
      identifier: "ForgotPassword.login"
    ) {
      store.send(.backTapped)
    }
    .padding(.top, Metrics.sectionSpacing)
  }
}

#Preview {
  NavigationStack {
    ForgotPasswordView(store: Store(initialState: ForgotPassword.State(step: .reset, email: "alice@example.com")) {
      ForgotPassword()
    })
  }
}
