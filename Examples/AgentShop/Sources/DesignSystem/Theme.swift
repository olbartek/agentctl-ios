import SwiftUI

/// Design tokens from the Figma "Authentication flow UI" file (colors, type, metrics). Names follow the file's
/// styles where it has them ("Neutral / 800", "Text/Black", "BG/Grey", …).
public enum Palette {
  /// Buttons and links. `#1443C3`
  public static let brand = Color(hex: 0x1443C3)
  /// Titles and body text ("Neutral / 800"). `#191D23`
  public static let textPrimary = Color(hex: 0x191D23)
  /// Strong text on light surfaces ("Text/Black"). `#131212`
  public static let textBlack = Color(hex: 0x131212)
  /// Secondary text ("BG/Grey"). `#6C6F72`
  public static let textSecondary = Color(hex: 0x6C6F72)
  /// Muted helper text ("foreground/muted"). `#77707F`
  public static let textMuted = Color(hex: 0x77707F)
  /// Divider captions ("Neutral / 600"). `#4B5768`
  public static let textSubtle = Color(hex: 0x4B5768)
  /// Field labels: black at 75 %.
  public static let label = Color.black.opacity(0.75)
  /// Placeholders. `#BABABA`
  public static let placeholder = Color(hex: 0xBABABA)
  /// Field borders and dividers. `#CBD2E0`
  public static let border = Color(hex: 0xCBD2E0)
  /// Tinted surfaces: the Google button and the back button. `#F4F7FF`
  public static let surfaceTint = Color(hex: 0xF4F7FF)
  /// Error text and icons. `#EA2A2A`
  public static let error = Color(hex: 0xEA2A2A)
  /// A checked checkbox. `#59CDBE`
  public static let checkboxOn = Color(hex: 0x59CDBE)
  /// Text on the brand color ("BG/white"). `#FEFEFE`
  public static let onBrand = Color(hex: 0xFEFEFE)
  /// Screen background.
  public static let background = Color.white
}

/// Type styles from the design. SF Pro Display is the system font.
public enum Typography {
  public static let screenTitle = Font.system(size: 24, weight: .bold)
  public static let pageTitle = Font.system(size: 24, weight: .medium)
  public static let body = Font.system(size: 14)
  public static let bodyMedium = Font.system(size: 14, weight: .medium)
  public static let input = Font.system(size: 16, weight: .medium)
  public static let button = Font.system(size: 16, weight: .medium)
  public static let sectionLabel = Font.system(size: 16, weight: .bold)
  public static let caption = Font.system(size: 12)
  public static let link = Font.system(size: 16)
}

/// Spacing and sizes from the design (a 428 pt wide frame with a 372 pt content column).
public enum Metrics {
  public static let screenPadding: CGFloat = 28
  public static let fieldHeight: CGFloat = 44
  public static let fieldRadius: CGFloat = 6
  public static let buttonHeight: CGFloat = 50
  public static let socialButtonHeight: CGFloat = 51
  public static let socialButtonRadius: CGFloat = 7.88
  /// Between sections (social sign-in, the form, the footer).
  public static let sectionSpacing: CGFloat = 40
  /// Between fields.
  public static let fieldSpacing: CGFloat = 24
}

extension Color {
  /// A color from a 24-bit RGB hex value, e.g. `0x1443C3`.
  public init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}
