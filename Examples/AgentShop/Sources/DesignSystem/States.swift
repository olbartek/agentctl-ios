import SwiftUI

public struct LoadingView: View {
  let title: String

  public init(_ title: String = "Loading…") {
    self.title = title
  }

  public var body: some View {
    ProgressView(title)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A full-screen error with an optional retry action.
public struct ErrorView: View {
  let message: String
  let code: String?
  let retryIdentifier: String
  let retry: (() -> Void)?

  /// - Parameters:
  ///   - code: the screen's `error=<code>`; the message gets the identifier `error:<code>`.
  ///   - retryIdentifier: the retry button's identifier, `<Screen>.retry` by the UI tests' convention.
  public init(_ message: String, code: String? = nil, retryIdentifier: String = "error.retry", retry: (() -> Void)? = nil) {
    self.message = message
    self.code = code
    self.retryIdentifier = retryIdentifier
    self.retry = retry
  }

  public var body: some View {
    ContentUnavailableView {
      Label("Something went wrong", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
        .accessibilityIdentifier(code.map { "error:\($0)" } ?? "error.message")
    } actions: {
      if let retry {
        Button("Try again", action: retry)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier(retryIdentifier)
      }
    }
  }
}

public struct EmptyStateView: View {
  let title: String
  let message: String
  let systemImage: String

  public init(_ title: String, message: String, systemImage: String = "tray") {
    self.title = title
    self.message = message
    self.systemImage = systemImage
  }

  public var body: some View {
    ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
  }
}

/// A short error line under a field or form: the design's warning icon and 12 pt red text.
public struct InlineError: View {
  let message: String
  let code: String?

  /// - Parameter code: the error code the screen reports as `error=<code>`. It becomes the view's
  ///   accessibility identifier, `error:<code>`, which is how a UI test asserts on the same error a script does.
  public init(_ message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Icon.warning.image
        .resizable()
        .frame(width: 14.67, height: 12.67)
        .frame(width: 16, height: 16)
      Text(message)
        .font(Typography.caption)
        .lineSpacing(3)
        .foregroundStyle(Palette.error)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(code.map { "error:\($0)" } ?? "inline.error")
  }
}

extension View {
  /// A compact navigation title on iOS; a no-op on macOS.
  public func inlineNavigationTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
}

#Preview {
  VStack {
    ErrorView("The network is unreachable.") {}
    EmptyStateView("No orders yet", message: "Orders you place will show up here.")
    InlineError("Wrong email or password.")
  }
}
