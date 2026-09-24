import SwiftUI

/// The top of an auth screen: an optional back button, then the title.
///
/// - `.centered`: a bold title centered below the back button's row ("Login", "Signup").
/// - `.leading`: a medium title with a subtitle, aligned to the leading edge ("Forgot Password").
public struct ScreenHeader: View {
  public enum Style: Sendable {
    case centered
    case leading(subtitle: String?)
  }

  let title: String
  let style: Style
  let onBack: (() -> Void)?

  public init(_ title: String, style: Style = .centered, onBack: (() -> Void)? = nil) {
    self.title = title
    self.style = style
    self.onBack = onBack
  }

  public var body: some View {
    switch style {
    case .centered:
      ZStack(alignment: .topLeading) {
        Text(title)
          .font(Typography.screenTitle)
          .foregroundStyle(Palette.textPrimary)
          .frame(maxWidth: .infinity)
          .padding(.top, 34)
          .accessibilityAddTraits(.isHeader)
        if let onBack {
          BackButton(action: onBack)
        }
      }
    case let .leading(subtitle):
      VStack(alignment: .leading, spacing: 0) {
        if let onBack {
          BackButton(action: onBack)
        } else {
          Color.clear.frame(height: 40)
        }
        Text(title)
          .font(Typography.pageTitle)
          .tracking(0.72)
          .foregroundStyle(Palette.textPrimary)
          .padding(.top, 33)
          .accessibilityAddTraits(.isHeader)
        if let subtitle {
          Text(subtitle)
            .font(Typography.body)
            .tracking(0.42)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The auth screens' page: a white, light-mode scroll view with the design's 28 pt side margins and no
/// navigation bar (screens draw their own header).
public struct FormScreen<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, Metrics.screenPadding)
      .padding(.top, 4)
      .padding(.bottom, 32)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Palette.background.ignoresSafeArea())
    .hideNavigationBar()
    .environment(\.colorScheme, .light)
  }
}

extension View {
  /// Hides the system navigation bar on iOS (the auth screens draw their own header). A no-op on macOS.
  public func hideNavigationBar() -> some View {
    #if os(iOS)
      toolbar(.hidden, for: .navigationBar)
    #else
      self
    #endif
  }
}

#Preview {
  NavigationStack {
    FormScreen {
      ScreenHeader("Forgot Password", style: .leading(subtitle: "Enter the email address registered with your account.")) {}
    }
  }
}
