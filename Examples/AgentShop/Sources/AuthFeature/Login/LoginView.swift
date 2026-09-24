import ComposableArchitecture
import DesignSystem
import SwiftUI

/// The Figma "Log in" frame. Login is the root of the auth stack, so it has no back button.
public struct LoginView: View {
  @Bindable var store: StoreOf<Login>

  public init(store: StoreOf<Login>) {
    self.store = store
  }

  public var body: some View {
    FormScreen {
      ScreenHeader("Login")

      GoogleButton("Sign in with Google", isLoading: store.isGoogleLoading, identifier: "login.google") {
        store.send(.googleTapped)
      }
      .padding(.top, 72)

      DividerLabel("or sign in with")
        .padding(.top, 24)

      VStack(spacing: Metrics.fieldSpacing) {
        FormField("Email Address") {
          ASTextField("name@example.com", text: $store.email, kind: .email, identifier: "login.email")
        }
        FormField("Password", error: store.error?.message) {
          LinkButton("Forgot Password", identifier: "login.forgot") {
            store.send(.forgotPasswordTapped)
          }
        } input: {
          ASSecureField(text: $store.password, isRevealed: $store.showPassword, identifier: "login.password")
        }
      }
      .padding(.top, Metrics.sectionSpacing)

      Checkbox(isOn: $store.keepSignedIn, identifier: "login.keepSignedIn") {
        Text("Keep me signed in")
          .font(Typography.body)
          .foregroundStyle(Palette.textBlack)
      }
      .padding(.top, 32)

      PrimaryButton("Login", isLoading: store.isLoading, isEnabled: store.canSubmit, identifier: "login.submit") {
        store.send(.submitTapped)
      }
      .padding(.top, 16)

      LinkButton("Log in with a one-time code", identifier: "login.useOTP") {
        store.send(.useOTPTapped)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 24)

      PromptLink("Don’t have an Account?", link: "Sign up here", identifier: "login.register") {
        store.send(.registerTapped)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 32)
    }
  }
}

#Preview {
  NavigationStack {
    LoginView(store: Store(initialState: Login.State(email: "alice@example.com")) { Login() })
  }
}
