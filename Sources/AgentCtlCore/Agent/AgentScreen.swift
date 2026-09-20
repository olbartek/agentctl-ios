/// One `key=value` pair in a step summary.
public struct SummaryItem: Codable, Equatable, Hashable, Sendable {
  public var key: String
  public var value: String

  public init(_ key: String, _ value: String) {
    self.key = key
    self.value = value
  }

  public init(_ key: String, _ value: Bool) {
    self.init(key, value ? "true" : "false")
  }

  public init(_ key: String, _ value: Int) {
    self.init(key, String(value))
  }
}

/// One screen of an app, described for agents: its path, its summary, its error code and its commands.
/// Conformance lives beside the reducer, in `<Screen>+Agent.swift`; `Examples/TinyApp` has two of them.
///
/// The associated types are named `AgentState`/`AgentAction` rather than `State`/`Action` so that a TCA
/// reducer can conform without making `Root.State` ambiguous in generic code; conformances infer them.
public protocol AgentScreen {
  associatedtype AgentState: Equatable
  associatedtype AgentAction: Sendable
  /// Shown as the command source in `appctl screens`. Defaults to the type name.
  static var screenName: String { get }
  /// Every path this screen can report, for the docs (`<id>` stands for a variable part).
  static var screenPaths: [String] { get }
  static func screenPath(_ state: AgentState) -> String
  /// Every key `summary` can emit, for the docs and `expect` error messages.
  static var summaryKeys: [String] { get }
  /// Ordered, compact key/value pairs. Never include secrets such as passwords.
  static func summary(_ state: AgentState) -> [SummaryItem]
  /// The current error code (`error=<code>`), if any.
  static func errorCode(_ state: AgentState) -> String?
  /// Sent by the headless runtime when the screen appears, standing in for SwiftUI's `onAppear`.
  static var onAppear: AgentAction? { get }
  static var commands: [AgentCommand<AgentState, AgentAction>] { get }
}

extension AgentScreen {
  public static var screenName: String { String(describing: Self.self) }
  public static func errorCode(_ state: AgentState) -> String? { nil }
  public static var onAppear: AgentAction? { nil }

  public static func activeScreen(_ state: AgentState) -> ActiveScreen<AgentAction> {
    let path = screenPath(state)
    return ActiveScreen(
      path: path,
      identity: path,
      summary: summary(state),
      errorCode: errorCode(state),
      appearAction: onAppear,
      commands: commands
        .filter { $0.paths?.contains(path) ?? true }
        .map { $0.resolve(state, source: screenName) }
    )
  }

  public static var screenDocs: [ScreenDoc] {
    screenPaths.map { path in
      ScreenDoc(
        path: path,
        screen: screenName,
        commands: commands.filter { $0.paths?.contains(path) ?? true }.map { $0.doc(source: screenName) },
        summaryKeys: summaryKeys
      )
    }
  }
}

/// A stack or tab container that resolves its active child, lifts the child's actions,
/// and appends its own commands (`back`, `tab`, …).
public protocol AgentContainer {
  associatedtype AgentState
  associatedtype AgentAction: Sendable
  static func activeScreen(_ state: AgentState) -> ActiveScreen<AgentAction>
  /// Every screen reachable through this container, with inherited commands appended.
  static var registry: [ScreenDoc] { get }
}

/// The screen an agent is looking at, with commands lifted to some ancestor's action type.
public struct ActiveScreen<Action> {
  public var path: String
  /// Changes whenever a different screen instance becomes active (path plus stack element ids).
  public var identity: String
  public var summary: [SummaryItem]
  public var errorCode: String?
  public var appearAction: Action?
  /// Leaf commands first, then ancestors'.
  public var commands: [ResolvedCommand<Action>]

  public init(
    path: String,
    identity: String,
    summary: [SummaryItem],
    errorCode: String?,
    appearAction: Action?,
    commands: [ResolvedCommand<Action>]
  ) {
    self.path = path
    self.identity = identity
    self.summary = summary
    self.errorCode = errorCode
    self.appearAction = appearAction
    self.commands = commands
  }

  public func map<Parent>(_ embed: @escaping @Sendable (Action) -> Parent) -> ActiveScreen<Parent> {
    ActiveScreen<Parent>(
      path: path,
      identity: identity,
      summary: summary,
      errorCode: errorCode,
      appearAction: appearAction.map(embed),
      commands: commands.map { $0.map(embed) }
    )
  }

  /// Appends ancestor commands. Commands that a descendant already provides keep the descendant's version.
  public func appending(_ extra: [ResolvedCommand<Action>]) -> Self {
    var copy = self
    let existing = Set(commands.map(\.name))
    copy.commands += extra.filter { !existing.contains($0.name) }
    return copy
  }

  /// Prefixes the identity, e.g. with a stack element id, so re-pushing the same path counts as a new appearance.
  public func identified(by component: String) -> Self {
    var copy = self
    copy.identity = "\(component)/\(identity)"
    return copy
  }

  public func command(named name: String) -> ResolvedCommand<Action>? {
    commands.first { $0.name == name }
  }
}

/// A command as documented by the CLI's `screens` command and the generated command reference.
public struct CommandDoc: Codable, Equatable, Hashable, Sendable {
  public var name: String
  public var argument: String?
  public var help: String
  public var source: String
  public var note: String?

  public init(name: String, argument: String?, help: String, source: String, note: String? = nil) {
    self.name = name
    self.argument = argument
    self.help = help
    self.source = source
    self.note = note
  }

  public var usage: String {
    argument.map { "\(name) \($0)" } ?? name
  }
}

/// A screen path with every command available there, including inherited ones.
public struct ScreenDoc: Codable, Equatable, Hashable, Sendable {
  public var path: String
  public var screen: String
  public var commands: [CommandDoc]
  public var summaryKeys: [String]

  public init(path: String, screen: String, commands: [CommandDoc], summaryKeys: [String]) {
    self.path = path
    self.screen = screen
    self.commands = commands
    self.summaryKeys = summaryKeys
  }

  public func inheriting(_ extra: [CommandDoc]) -> Self {
    var copy = self
    let existing = Set(commands.map(\.name))
    copy.commands += extra.filter { !existing.contains($0.name) }
    return copy
  }
}
