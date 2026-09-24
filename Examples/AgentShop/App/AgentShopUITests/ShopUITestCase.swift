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
      hittable(app.alerts.buttons[label], named: "alert button '\(label)'", line: line).tap()
      return
    }
    if id.hasPrefix("HomeTabs.tab."), let label = tabLabels[String(id.dropFirst("HomeTabs.tab.".count))] {
      // The tab bar is never covered by the keyboard, but a system sheet over the app swallows taps on it.
      dismissSystemPrompt()
      hittable(app.tabBars.buttons[label], named: "tab '\(label)'", line: line).tap()
      return
    }
    hittable(id, line: line).tap()
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
    if own.exists, isOnScreen(own) {
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

  /// A value a screen only shows when it is set (the applied promo code) counts as `none` when it is not shown.
  func expectValue(_ id: String, _ value: String, line: String) {
    let element = element(id)
    if value == "none", !poll({ element.exists }, timeout: 1) { return }
    require(poll { element.exists }, "no element \(id)", line)
    require(wait(for: element, value: value), "\(id) is '\(describe(element))', expected '\(value)'", line)
  }

  /// A button a screen hides when it can't be used (an order that can't be cancelled) counts as disabled.
  func expectEnabled(_ id: String, _ enabled: Bool, line: String) {
    let element = element(id)
    require(
      poll { enabled ? element.exists && element.isEnabled : !element.exists || !element.isEnabled },
      "\(id) is not \(enabled ? "enabled" : "disabled")", line
    )
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
    hittable(element(id), named: id, line: line)
  }

  private func hittable(_ element: XCUIElement, named name: String, line: String) -> XCUIElement {
    require(poll { element.exists }, "no element \(name)", line)
    // A system sheet over the app would swallow the tap, wherever the element is.
    dismissSystemPrompt()
    settleKeyboard()
    var attempts = 0
    while !isOnScreen(element), attempts < 8 {
      if !app.frame.contains(CGPoint(x: element.frame.midX, y: app.frame.midY)) {
        // Off to the side in a horizontal row (the category chips): drag the row.
        scrollRow(toward: element)
      } else if attempts % 2 == 0, visibleKeyboard != nil, tapReturnKey() {
        // A text keyboard's return key ends editing (the first tap may only accept a suggestion).
      } else {
        // A number pad has no return key; scrolling moves the element above it (and above the tab bar).
        app.swipeUp(velocity: .slow)
      }
      attempts += 1
      settleKeyboard()
    }
    require(isOnScreen(element), "\(name) is not on screen", line)
    return element
  }

  /// Whether a tap at the element's center would land on it: inside the window, and not under the keyboard or the
  /// tab bar (unless it is part of them). XCUIElement.isHittable is unreliable for SwiftUI on recent simulators.
  private func isOnScreen(_ element: XCUIElement) -> Bool {
    let frame = element.frame
    guard !frame.isEmpty else { return false }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    guard app.frame.contains(center) else { return false }
    var covers: [CGRect] = []
    if let keyboard = visibleKeyboard {
      // The suggestions bar above the keys is not part of the keyboard element, but covers the app all the same.
      var area = keyboard.frame
      area.origin.y -= 44
      area.size.height += 44
      covers.append(area)
    }
    if app.tabBars.firstMatch.exists { covers.append(app.tabBars.firstMatch.frame) }
    for area in covers where area.contains(center) && !area.contains(frame) {
      return false
    }
    return true
  }

  /// The keyboard on screen, if any. There can be more than one keyboard element (one parked below the screen), so
  /// `app.keyboards.firstMatch` may not be the one covering the app.
  private var visibleKeyboard: XCUIElement? {
    app.keyboards.allElementsBoundByIndex.first { $0.exists && $0.frame.minY < app.frame.maxY - 1 }
  }

  /// Waits until the keyboard has finished appearing or going away: until its frame (or its absence) holds still.
  private func settleKeyboard() {
    var last = visibleKeyboard?.frame ?? .null
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.1)
      let now = visibleKeyboard?.frame ?? .null
      if now == last { return }
      last = now
    }
  }

  /// Drags a horizontal row sideways, by its middle, so the element moves toward the middle of the screen.
  private func scrollRow(toward element: XCUIElement) {
    let window = app.frame
    let y = element.frame.midY / window.height
    let right = element.frame.midX > window.midX
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.8 : 0.2, dy: y))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.2 : 0.8, dy: y))
    start.press(forDuration: 0.05, thenDragTo: end)
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
    guard let keyboard = visibleKeyboard else { return false }
    for label in ["return", "Return", "done", "Done", "go", "Go", "next", "Next"] {
      let key = keyboard.buttons[label]
      // A keyboard that is sliding away still lists its keys, below the screen; tapping one fails slowly.
      if key.exists, app.frame.contains(CGPoint(x: key.frame.midX, y: key.frame.midY)) {
        key.tap()
        return true
      }
    }
    return false
  }

  /// Polls `condition` until it holds or `timeout` passes; on the way, clears a system prompt covering the app.
  private func poll(_ condition: () -> Bool, timeout: TimeInterval? = nil) -> Bool {
    let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
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

  /// An empty text field reports its placeholder as its value, so `""` also matches the placeholder.
  private func wait(for element: XCUIElement, value: String) -> Bool {
    poll {
      let current = element.value as? String
      // A switch or a checkbox shows on/off where the summary says true/false.
      let shown = ["on": "true", "off": "false"][current ?? ""] ?? current
      return current == value || shown == value || element.label == value
        || (value.isEmpty && (current == nil || current == element.placeholderValue))
    }
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
