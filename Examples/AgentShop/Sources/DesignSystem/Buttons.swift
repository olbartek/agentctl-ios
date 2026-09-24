import SwiftUI

/// The main call to action: a 50 pt capsule in the brand color. Shows a spinner while loading, and is disabled
/// when not enabled or while loading. Disabled, only the capsule fades, so the title stays readable.
public struct PrimaryButton: View {
  let title: String
  let isLoading: Bool
  let isEnabled: Bool
  let identifier: String?
  let action: () -> Void

  public init(
    _ title: String,
    isLoading: Bool = false,
    isEnabled: Bool = true,
    identifier: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.isLoading = isLoading
    self.isEnabled = isEnabled
    self.identifier = identifier
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      ZStack {
        Text(title)
          .font(Typography.button)
          .foregroundStyle(Palette.onBrand)
          .opacity(isLoading ? 0 : 1)
        if isLoading {
          ProgressView().tint(Palette.onBrand)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: Metrics.buttonHeight)
      .background(Capsule().fill(Palette.brand.opacity(isEnabled || isLoading ? 1 : 0.4)))
      .contentShape(Capsule())
    }
    .buttonStyle(PressDimmingStyle())
    .disabled(!isEnabled || isLoading)
    .accessibilityIdentifierIfPresent(identifier)
  }
}

/// Dims the label while pressed. Unlike `.plain`, it doesn't also fade a disabled button: the buttons draw their
/// own disabled look.
struct PressDimmingStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
  }
}

/// "Sign in with Google" / "Sign up with Google": the tinted social button with the Google logo.
public struct GoogleButton: View {
  let title: String
  let isLoading: Bool
  let identifier: String?
  let action: () -> Void

  public init(_ title: String, isLoading: Bool = false, identifier: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.isLoading = isLoading
    self.identifier = identifier
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading {
          ProgressView().frame(width: 18.9, height: 18.9)
        } else {
          Icon.googleLogo.image
            .resizable()
            .frame(width: 18.9, height: 18.9)
        }
        Text(title)
          .font(Typography.bodyMedium)
          .foregroundStyle(Palette.textBlack)
      }
      .frame(maxWidth: .infinity)
      .frame(height: Metrics.socialButtonHeight)
      .background(RoundedRectangle(cornerRadius: Metrics.socialButtonRadius).fill(Palette.surfaceTint))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isLoading)
    .accessibilityIdentifierIfPresent(identifier)
  }
}

/// A brand-colored text link, such as "Forgot Password" or "Resend". Grey when disabled.
public struct LinkButton: View {
  let title: String
  let font: Font
  let underlined: Bool
  let isEnabled: Bool
  let identifier: String?
  let action: () -> Void

  public init(
    _ title: String,
    font: Font = Typography.bodyMedium,
    underlined: Bool = false,
    isEnabled: Bool = true,
    identifier: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.font = font
    self.underlined = underlined
    self.isEnabled = isEnabled
    self.identifier = identifier
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Text(title)
        .font(font)
        .underline(underlined && isEnabled)
        .foregroundStyle(isEnabled ? Palette.brand : Palette.textSecondary)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityIdentifierIfPresent(identifier)
  }
}

/// A prompt followed by a link on one line: "Don't have an Account? Sign up here".
public struct PromptLink: View {
  let prompt: String
  let link: String
  let promptColor: Color
  let linkFont: Font
  let underlined: Bool
  let isEnabled: Bool
  let identifier: String?
  let action: () -> Void

  public init(
    _ prompt: String,
    link: String,
    promptColor: Color = Palette.textBlack,
    linkFont: Font = Typography.link,
    underlined: Bool = false,
    isEnabled: Bool = true,
    identifier: String? = nil,
    action: @escaping () -> Void
  ) {
    self.prompt = prompt
    self.link = link
    self.promptColor = promptColor
    self.linkFont = linkFont
    self.underlined = underlined
    self.isEnabled = isEnabled
    self.identifier = identifier
    self.action = action
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(prompt)
        .font(Typography.body)
        .foregroundStyle(promptColor)
      LinkButton(
        link, font: linkFont, underlined: underlined, isEnabled: isEnabled, identifier: identifier, action: action
      )
    }
  }
}

#Preview {
  VStack(spacing: 16) {
    GoogleButton("Sign in with Google") {}
    PrimaryButton("Login") {}
    PrimaryButton("Login", isLoading: true) {}
    PrimaryButton("Login", isEnabled: false) {}
    PromptLink("Don’t have an Account?", link: "Sign up here") {}
  }
  .padding(28)
}
