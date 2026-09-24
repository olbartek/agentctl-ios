import SwiftUI

/// The round back button in the top-left corner of the auth screens.
public struct BackButton: View {
  let identifier: String?
  let action: () -> Void

  public init(identifier: String? = "nav.back", action: @escaping () -> Void) {
    self.identifier = identifier
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Icon.arrowLeft.image
        .resizable()
        .frame(width: 32, height: 32)
        .padding(4)
        .background(Circle().fill(Palette.surfaceTint))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Back")
    .accessibilityIdentifierIfPresent(identifier)
  }
}

/// A checkbox with a label. Unchecked: a brand-outlined square; checked: a teal square with a white checkmark.
public struct Checkbox<Label: View>: View {
  @Binding var isOn: Bool
  let spacing: CGFloat
  let identifier: String?
  let label: Label

  public init(isOn: Binding<Bool>, spacing: CGFloat = 8, identifier: String? = nil, @ViewBuilder label: () -> Label) {
    self._isOn = isOn
    self.spacing = spacing
    self.identifier = identifier
    self.label = label()
  }

  public var body: some View {
    Button {
      isOn.toggle()
    } label: {
      HStack(alignment: .top, spacing: spacing) {
        ZStack {
          if isOn {
            RoundedRectangle(cornerRadius: 4).fill(Palette.checkboxOn)
            Icon.checkmark.image
              .resizable()
              .frame(width: 16, height: 16)
          } else {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.brand, lineWidth: 1)
          }
        }
        .frame(width: 20, height: 20)
        label
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifierIfPresent(identifier)
  }
}

/// A horizontal rule with a centered caption: "or sign in with".
public struct DividerLabel: View {
  let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    ZStack {
      Rectangle()
        .fill(Palette.border)
        .frame(height: 1)
      Text(text)
        .font(Typography.bodyMedium)
        .foregroundStyle(Palette.textSubtle)
        .lineLimit(1)
        .padding(8)
        .background(Palette.background)
    }
    .frame(height: 36)
  }
}

#Preview {
  VStack(alignment: .leading, spacing: 24) {
    BackButton {}
    Checkbox(isOn: .constant(true)) { Text("Keep me signed in") }
    Checkbox(isOn: .constant(false), spacing: 16) { Text("I accept the terms") }
    DividerLabel("or sign in with")
  }
  .padding(28)
}
