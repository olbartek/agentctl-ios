import SwiftUI

/// Icons exported from the Figma file, stored as vector SVGs in `Resources/Assets.xcassets`.
///
/// The asset catalog is compiled by Xcode builds (the app, snapshot tests). A command-line `swift build` on the
/// Mac doesn't compile it, which is fine: headless runs never render views.
public enum Icon: String, CaseIterable, Sendable {
  case googleLogo = "GoogleLogo"
  case eyeSlash = "EyeSlash"
  case warning = "Warning"
  case checkmark = "Checkmark"
  case arrowLeft = "ArrowLeft"

  public var image: Image {
    Image(rawValue, bundle: .module)
  }
}
