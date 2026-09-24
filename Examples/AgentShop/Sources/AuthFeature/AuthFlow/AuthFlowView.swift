import ComposableArchitecture
import SwiftUI

public struct AuthFlowView: View {
  @Bindable var store: StoreOf<AuthFlow>

  public init(store: StoreOf<AuthFlow>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      LoginView(store: store.scope(state: \.login, action: \.login))
    } destination: { store in
      switch store.case {
      case let .otpLogin(store):
        OTPLoginView(store: store)
      case let .register(store):
        RegisterView(store: store)
      case let .verifyEmail(store):
        VerifyEmailView(store: store)
      case let .forgotPassword(store):
        ForgotPasswordView(store: store)
      }
    }
  }
}
