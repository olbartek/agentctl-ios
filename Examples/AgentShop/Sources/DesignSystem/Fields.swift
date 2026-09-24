import Foundation
import SwiftUI

/// What a text field holds. Drives keyboard, autofill and capitalization on iOS.
public enum FieldKind: Sendable {
  case plain
  case name
  case email
  case oneTimeCode
}

/// What a secure field holds. Drives password autofill on iOS.
public enum SecureFieldKind: Sendable {
  case password
  case newPassword
}

/// A labeled form field (the design's "Input Field"): a label row with an optional trailing accessory such as
/// a "Forgot Password" link, the input, and an optional error line.
public struct FormField<Accessory: View, Input: View>: View {
  let label: String
  let error: String?
  let errorCode: String?
  let accessory: Accessory
  let input: Input

  /// - Parameter errorCode: the screen's `error=<code>` when `error` shows it (see ``InlineError``).
  public init(
    _ label: String,
    error: String? = nil,
    errorCode: String? = nil,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder input: () -> Input
  ) {
    self.label = label
    self.error = error
    self.errorCode = errorCode
    self.accessory = accessory()
    self.input = input()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(label)
          .font(Typography.body)
          .foregroundStyle(Palette.label)
        Spacer(minLength: 8)
        accessory
      }
      input
      if let error {
        InlineError(error, code: errorCode)
      }
    }
  }
}

extension FormField where Accessory == EmptyView {
  public init(_ label: String, error: String? = nil, errorCode: String? = nil, @ViewBuilder input: () -> Input) {
    self.init(label, error: error, errorCode: errorCode, accessory: { EmptyView() }, input: input)
  }
}

/// A bordered text input (the design's "Text Input").
public struct ASTextField: View {
  let placeholder: String
  @Binding var text: String
  let kind: FieldKind
  let identifier: String?

  public init(_ placeholder: String, text: Binding<String>, kind: FieldKind = .plain, identifier: String? = nil) {
    self.placeholder = placeholder
    self._text = text
    self.kind = kind
    self.identifier = identifier
  }

  public var body: some View {
    TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Palette.placeholder))
      .font(Typography.input)
      .foregroundStyle(Palette.textPrimary)
      .modifier(FieldKindModifier(kind: kind))
      .textFieldStyle(.plain)
      .fieldChrome()
      .accessibilityIdentifierIfPresent(identifier)
  }
}

/// A bordered password input with a show/hide toggle. Whether the text is revealed is state owned by the
/// screen's reducer (bind it like any other field).
public struct ASSecureField: View {
  let placeholder: String
  @Binding var text: String
  @Binding var isRevealed: Bool
  let kind: SecureFieldKind
  let identifier: String?
  let revealIdentifier: String?

  /// - Parameter revealIdentifier: the show/hide button's identifier; `<identifier>.reveal` when omitted.
  public init(
    _ placeholder: String = "••••••••",
    text: Binding<String>,
    isRevealed: Binding<Bool>,
    kind: SecureFieldKind = .password,
    identifier: String? = nil,
    revealIdentifier: String? = nil
  ) {
    self.placeholder = placeholder
    self._text = text
    self._isRevealed = isRevealed
    self.kind = kind
    self.identifier = identifier
    self.revealIdentifier = revealIdentifier ?? identifier.map { "\($0).reveal" }
  }

  public var body: some View {
    HStack(spacing: 4) {
      Group {
        if isRevealed {
          TextField(placeholder, text: $text, prompt: prompt)
            .modifier(SecureFieldKindModifier(kind: kind))
        } else {
          SecureField(placeholder, text: $text, prompt: prompt)
            .modifier(SecureFieldKindModifier(kind: kind))
        }
      }
      .font(Typography.input)
      .foregroundStyle(Palette.textPrimary)
      .textFieldStyle(.plain)
      .accessibilityIdentifierIfPresent(identifier)

      Button {
        isRevealed.toggle()
      } label: {
        Group {
          if isRevealed {
            // The design only has the "hidden" state's icon (eye-slash); the "revealed" state uses the matching SF Symbol.
            Image(systemName: "eye")
              .font(.system(size: 15))
              .foregroundStyle(Palette.textSecondary)
          } else {
            Icon.eyeSlash.image
              .resizable()
              .frame(width: 20, height: 20)
          }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
      .accessibilityValue(isRevealed ? "on" : "off")
      .accessibilityIdentifierIfPresent(revealIdentifier)
    }
    .fieldChrome()
  }

  private var prompt: Text {
    Text(placeholder).foregroundStyle(Palette.placeholder)
  }
}

/// The design's 6-box code entry ("Enter Code"). A single hidden text field takes the input, so paste and
/// one-time-code autofill work; the boxes show one digit each, or "-".
public struct CodeInputField: View {
  @Binding var code: String
  let length: Int
  let identifier: String?
  @FocusState private var isFocused: Bool

  public init(code: Binding<String>, length: Int = 6, identifier: String? = nil) {
    self._code = code
    self.length = length
    self.identifier = identifier
  }

  public var body: some View {
    ZStack {
      TextField("", text: $code)
        .modifier(FieldKindModifier(kind: .oneTimeCode))
        .focused($isFocused)
        .foregroundStyle(.clear)
        .tint(.clear)
        .opacity(0.02)
        .accessibilityIdentifierIfPresent(identifier)
      ViewThatFits(in: .horizontal) {
        boxes(spacing: 16, width: 48)
        boxes(spacing: 8, width: nil)
      }
      .contentShape(Rectangle())
      .onTapGesture { isFocused = true }
      .accessibilityHidden(true)
    }
  }

  private func boxes(spacing: CGFloat, width: CGFloat?) -> some View {
    HStack(spacing: spacing) {
      ForEach(0..<length, id: \.self) { index in
        let digit = digit(at: index)
        Text(digit ?? "-")
          .font(Typography.input)
          .foregroundStyle(digit == nil ? Palette.placeholder : Palette.textPrimary)
          .frame(width: width, height: Metrics.fieldHeight)
          .frame(maxWidth: width == nil ? .infinity : nil)
          .background(
            RoundedRectangle(cornerRadius: Metrics.fieldRadius)
              .strokeBorder(isActive(index) ? Palette.brand : Palette.border, lineWidth: 1)
              .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius).fill(Palette.background))
          )
      }
    }
  }

  private func digit(at index: Int) -> String? {
    let characters = Array(code)
    return index < characters.count ? String(characters[index]) : nil
  }

  private func isActive(_ index: Int) -> Bool {
    isFocused && index == min(code.count, length - 1)
  }
}

extension View {
  /// The design's text input chrome: 44 pt tall, 12 pt horizontal padding, a 1 pt border and 6 pt corners.
  func fieldChrome() -> some View {
    padding(.horizontal, 12)
      .frame(height: Metrics.fieldHeight)
      .background(
        RoundedRectangle(cornerRadius: Metrics.fieldRadius)
          .strokeBorder(Palette.border, lineWidth: 1)
          .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius).fill(Palette.background))
      )
  }
}

struct FieldKindModifier: ViewModifier {
  let kind: FieldKind

  func body(content: Content) -> some View {
    #if os(iOS)
      switch kind {
      case .plain:
        content
      case .name:
        content
          .textContentType(.name)
          .textInputAutocapitalization(.words)
      case .email:
        content
          .keyboardType(.emailAddress)
          .textContentType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      case .oneTimeCode:
        content
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
      }
    #else
      content.autocorrectionDisabled(kind != .plain)
    #endif
  }
}

struct SecureFieldKindModifier: ViewModifier {
  let kind: SecureFieldKind

  /// `-ui-testing`: XCUITests launch the app with it. On a simulator, a `.newPassword` field makes iOS fill in a
  /// suggested strong password over whatever the test types, and a `.password` field ends in a "Save Password?"
  /// sheet. Every UI-tested app needs a switch like this; headless runs never render a field at all.
  static let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")

  func body(content: Content) -> some View {
    #if os(iOS)
      if Self.isUITesting {
        content.textContentType(.oneTimeCode).textInputAutocapitalization(.never)
      } else {
        switch kind {
        case .password: content.textContentType(.password).textInputAutocapitalization(.never)
        case .newPassword: content.textContentType(.newPassword).textInputAutocapitalization(.never)
        }
      }
    #else
      content
    #endif
  }
}

extension View {
  /// Applies an accessibility identifier only when one is given.
  @ViewBuilder
  func accessibilityIdentifierIfPresent(_ identifier: String?) -> some View {
    if let identifier {
      accessibilityIdentifier(identifier)
    } else {
      self
    }
  }
}

#Preview {
  VStack(spacing: 24) {
    FormField("Email Address") {
      ASTextField("Rhebhek@gmail.com", text: .constant(""), kind: .email)
    }
    FormField("Password", error: "Please enter correct password") {
      ASSecureField(text: .constant("secret"), isRevealed: .constant(false))
    }
    CodeInputField(code: .constant("123"))
  }
  .padding(28)
}
