import SwiftUI

// The contract between AgentShop's views and its generated XCUITests (`bench/gen_uitests.py`). A UI test drives
// exactly what a scenario script drives, so every element a script command stands for carries an identifier
// derived from that command:
//
// | Element                                  | Identifier                          |
// |------------------------------------------|-------------------------------------|
// | The screen                               | `screen:<path>` (``screenIdentifier(_:)``) |
// | A command's button, field or switch       | `<Screen>.<command>`                |
// | A command's choice, e.g. `tab cart`       | `<Screen>.<command>.<argument>`     |
// | A summary value shown on screen           | `<Screen>.<key>`, with the value as `accessibilityValue` |
// | An error                                 | `error:<code>` (``InlineError``, ``ErrorView``) |
// | A container's `back`                     | `nav.back` (``BackButton``)         |
//
// `<Screen>` is the `AgentScreen`'s type name, as `./appctl screens` prints it in brackets.

extension View {
  /// Marks a screen for UI tests as `screen:<path>`, the same path the agent layer reports. Pass the screen's
  /// own `screenPath(_:)`, so the two can never disagree.
  public func screenIdentifier(_ path: String) -> some View {
    accessibilityElement(children: .contain)
      .accessibilityIdentifier("screen:\(path)")
  }

  /// A summary value shown on screen: identifier `<Screen>.<key>`, value exactly as the step output prints it.
  public func summaryValue(_ identifier: String, _ value: String) -> some View {
    accessibilityIdentifier(identifier)
      .accessibilityValue(value)
  }
}
