import XCTest

/// The driver every generated UI test runs on (`Generated/*UITests.swift`, written by `bench/gen_uitests.py`).
///
/// A generated test replays one scenario file through the real UI: each script command becomes a tap, some
/// typing or a switch, and each `expect` becomes a wait for what the screen shows. Elements are found by the
/// identifiers in `DesignSystem/UITestIdentifiers.swift`. Every call takes the scenario line it came from, and a
/// failure names it (`auth-login-happy-path.appctl:7  submit`).
///
/// The app is launched the way the benchmark launches it for the bridge: no saved session, no mock latency. A
/// scenario's `mock` lines become `-mock-fault <method>#<n>=<code>` launch arguments, since a UI test cannot
/// send them later.
@MainActor
class ShopUITestCase: XCTestCase {
  var app: XCUIApplication!

  /// How long to wait for a screen, an element or a value.
  let timeout: TimeInterval = 10

  /// Tab bar items have no identifiers of their own; `HomeTabs.tab.<tab>` taps the tab with this label.
  let tabLabels = ["shop": "Shop", "cart": "Cart", "orders": "Orders", "profile": "Profile"]

  /// Alert buttons have no identifiers either; these commands tap the button with this label.
  let alertButtons = ["Profile.confirm": "Log out", "Profile.dismiss": "Cancel"]

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
  }

  func launch(faults: [String] = []) {
    app = XCUIApplication()
    // An ephemeral bridge port, so the running app never clashes with another copy's bridge.
    // `-ui-testing` turns off the password autofill hints that fight XCUITest typing (see DesignSystem/Fields.swift).
    app.launchArguments = ["-ui-testing", "-clear-session", "-mock-latency", "0", "-agent-port", "0"]
      + faults.flatMap { ["-mock-fault", $0] }
    app.launch()
  }

  // MARK: Commands

  func tap(_ id: String, line: String) {
    if let label = alertButtons[id] {
      let button = app.alerts.buttons[label]
      require(poll { button.exists }, "no alert button '\(label)'", line)
      button.tap()
      return
    }
    if id.hasPrefix("HomeTabs.tab."), let label = tabLabels[String(id.dropFirst("HomeTabs.tab.".count))] {
      let button = app.tabBars.buttons[label]
      require(poll { button.exists }, "no tab '\(label)'", line)
      button.tap()
      return
    }
    let element = hittable(id, line: line)
    element.tap()
  }

  func type(_ id: String, _ text: String, line: String) {
    let element = hittable(id, line: line)
    element.tap()
    clear(element)
    if !text.isEmpty {
      element.typeText(text)
    }
  }

  func setSwitch(_ id: String, _ on: Bool, line: String) {
    let element = hittable(id, line: line)
    if (element.value as? String) != (on ? "on" : "off") {
      element.tap()
    }
    require(wait(for: element, value: on ? "on" : "off"), "\(id) did not turn \(on ? "on" : "off")", line)
  }

  /// `back`: the screen's own back button if it draws one, else the navigation bar's.
  func back(line: String) {
    let own = app.buttons["nav.back"].firstMatch
    if own.exists, own.isHittable {
      own.tap()
      return
    }
    let bar = app.navigationBars.buttons.element(boundBy: 0)
    require(poll { bar.exists }, "no back button", line)
    bar.tap()
  }

  // MARK: Expectations

  func expectScreen(_ path: String, line: String) {
    let marker = element("screen:\(path)")
    require(poll { marker.exists }, "screen \(path) did not appear", line)
  }

  func expectValue(_ id: String, _ value: String, line: String) {
    let element = element(id)
    require(poll { element.exists }, "no element \(id)", line)
    require(wait(for: element, value: value), "\(id) is '\(describe(element))', expected '\(value)'", line)
  }

  func expectEnabled(_ id: String, _ enabled: Bool, line: String) {
    let element = element(id)
    require(poll { element.exists && element.isEnabled == enabled }, "\(id) is not \(enabled ? "enabled" : "disabled")", line)
  }

  func expectError(_ code: String, line: String) {
    let error = element("error:\(code)")
    require(poll { error.exists }, "error \(code) is not shown", line)
  }

  func expectNoError(line: String) {
    let errors = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'error:'"))
    require(poll { errors.count == 0 }, "an error is shown: \(errors.firstMatch.identifier)", line)
  }

  // MARK: Helpers

  private func element(_ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Waits for the element, then gets it on screen: dismisses a system prompt that covers the app, hides the
  /// keyboard, scrolls. Costs nothing when the element is already tappable.
  private func hittable(_ id: String, line: String) -> XCUIElement {
    let element = element(id)
    require(poll { element.exists }, "no element \(id)", line)
    var attempts = 0
    while !element.isHittable, attempts < 8 {
      if dismissSystemPrompt() {
        // Nothing else to do: the prompt was what covered the element.
      } else if attempts == 0, app.keyboards.count > 0, tapReturnKey() {
        // A text keyboard's return key ends editing.
      } else {
        // A number pad has no return key; scrolling moves the element above the keyboard instead.
        app.swipeUp(velocity: .slow)
      }
      attempts += 1
    }
    require(element.isHittable, "\(id) cannot be tapped", line)
    return element
  }

  /// iOS offers to save a password after a login form goes away. It is a system sheet over the app; "Not Now"
  /// closes it. Returns whether there was one.
  @discardableResult
  private func dismissSystemPrompt() -> Bool {
    let notNow = app.buttons["Not Now"]
    guard notNow.exists else { return false }
    notNow.tap()
    return true
  }

  /// Taps the keyboard's return key, if it has one. Returns whether it did.
  private func tapReturnKey() -> Bool {
    let keyboard = app.keyboards.firstMatch
    for label in ["return", "Return", "done", "Done", "go", "Go", "next", "Next"] {
      let key = keyboard.buttons[label]
      if key.exists {
        key.tap()
        return true
      }
    }
    return false
  }

  /// Polls `condition` until it holds or `timeout` passes; on the way, clears a system prompt covering the app.
  private func poll(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      dismissSystemPrompt()
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  /// Deletes the field's contents. An empty field reports its placeholder as its value, which can't be told apart
  /// from real text (a secure field's placeholder is bullets, like its text), so this deletes that many
  /// characters either way; deleting in an empty field does nothing.
  private func clear(_ element: XCUIElement) {
    guard let current = element.value as? String, !current.isEmpty else { return }
    element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
  }

  private func wait(for element: XCUIElement, value: String) -> Bool {
    poll { (element.value as? String) == value || element.label == value }
  }

  private func describe(_ element: XCUIElement) -> String {
    (element.value as? String) ?? element.label
  }

  /// Fails with the scenario line, and attaches what the app showed: a screenshot and its element tree.
  private func require(_ condition: Bool, _ message: @autoclosure () -> String, _ line: String) {
    guard !condition else { return }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Screen at failure"
    add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "Element tree at failure"
    add(tree)
    XCTFail("\(line): \(message())")
  }
}
