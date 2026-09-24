import ComposableArchitecture
import DesignSystem
import Models
import SwiftUI

/// The Figma "Signup" frame.
public struct RegisterView: View {
  @Bindable var store: StoreOf<Register>

  public init(store: StoreOf<Register>) {
    self.store = store
  }

  public var body: some View {
    FormScreen {
      ScreenHeader("Signup") {
        store.send(.backTapped)
      }

      GoogleButton("Sign up with Google", isLoading: store.isGoogleLoading, identifier: "Register.google") {
        store.send(.googleTapped)
      }
      .padding(.top, Metrics.sectionSpacing)

      DividerLabel("or sign up with")
        .padding(.top, 24)

      VStack(spacing: Metrics.fieldSpacing) {
        FormField("Full Name") {
          ASTextField("Your name", text: $store.name, kind: .name, identifier: "Register.name")
        }
        FormField("Email Address", error: store.emailFieldIssues.message) {
          ASTextField("name@example.com", text: $store.email, kind: .email, identifier: "Register.email")
        }
        FormField("Password", error: store.passwordFieldIssues.message) {
          ASSecureField(
            text: $store.password,
            isRevealed: $store.showPassword,
            kind: .newPassword,
            identifier: "Register.password",
            revealIdentifier: "Register.show-password"
          )
        }
        FormField("Confirm Password", error: store.confirmFieldIssues.message) {
          ASSecureField(
            text: $store.confirm,
            isRevealed: $store.showConfirm,
            kind: .newPassword,
            identifier: "Register.confirm",
            revealIdentifier: "Register.show-confirm"
          )
        }
      }
      .padding(.top, Metrics.sectionSpacing)

      Checkbox(isOn: $store.acceptedTerms, spacing: 16, identifier: "Register.terms") {
        Text("By creating an account, I accept AgentShop’s Terms of Use and Privacy Policy")
          .font(Typography.body)
          .foregroundStyle(Palette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 32)

      if let error = store.error {
        InlineError(error.message, code: error.rawValue)
          .padding(.top, 16)
      }

      PrimaryButton("Signup", isLoading: store.isLoading, isEnabled: store.canSubmit, identifier: "Register.submit") {
        store.send(.submitTapped)
      }
      .padding(.top, 16)

      PromptLink("Have an Account?", link: "Sign in here", identifier: "Register.sign-in") {
        store.send(.backTapped)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 32)
    }
    .screenIdentifier(Register.screenPath(store.state))
  }
}

#Preview {
  NavigationStack {
    RegisterView(store: Store(initialState: Register.State(email: "carol@", password: "short")) { Register() })
  }
}
