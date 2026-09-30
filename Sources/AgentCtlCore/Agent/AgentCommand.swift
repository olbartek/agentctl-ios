/// Why an agent command could not be turned into an action.
public enum AgentCommandError: Error, Equatable, Sendable {
  /// The command needs an argument, described by the associated value (e.g. `"<text>"`).
  case missingArgument(String)
  /// The command takes no argument but got one.
  case unexpectedArgument(String)
  /// The argument was given but is not valid.
  case invalidArgument(String)
  /// The command exists but does not apply in the current state (e.g. `back` with nothing to pop).
  case notApplicable(String)

  public var message: String {
    switch self {
    case let .missingArgument(expected): "missing argument: expected \(expected)"
    case let .unexpectedArgument(argument): "unexpected argument '\(argument)': this command takes none"
    case let .invalidArgument(reason): "invalid argument: \(reason)"
    case let .notApplicable(reason): reason
    }
  }
}

/// Disables a command in some states, mirroring a disabled button.
public struct CommandGate<State>: Sendable {
  /// Shown when the command is disabled, e.g. `"canSubmit=false"`.
  public var hint: String
  public var isEnabled: @Sendable (State) -> Bool

  public init(hint: String, isEnabled: @escaping @Sendable (State) -> Bool) {
    self.hint = hint
    self.isEnabled = isEnabled
  }
}

/// One command an agent can send on a screen. Conformances live in `<Screen>+Agent.swift`.
public struct AgentCommand<State, Action>: Sendable {
  public var name: String
  /// Describes the argument, e.g. `"<text>"` or `"<on|off>"`; `nil` if the command takes none.
  public var argument: String?
  /// One line, shown by `appctl screens` and in the generated docs.
  public var help: String
  /// The screen paths this command is offered on; `nil` means every path of the screen.
  public var paths: [String]?
  /// Disables the command in some states; `nil` means always enabled.
  public var gate: CommandGate<State>?
  /// A note for the docs, e.g. `"when the stack is not empty"`.
  public var note: String?
  public var makeAction: @Sendable (String?) throws(AgentCommandError) -> Action

  public init(
    name: String,
    argument: String?,
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    makeAction: @escaping @Sendable (String?) throws(AgentCommandError) -> Action
  ) {
    self.name = name
    self.argument = argument
    self.help = help
    self.paths = paths
    self.gate = gate
    self.note = note
    self.makeAction = makeAction
  }

  public func doc(source: String) -> CommandDoc {
    CommandDoc(name: name, argument: argument, help: help, source: source, note: note ?? gate.map { "disabled when \($0.hint)" })
  }

  public func resolve(_ state: State, source: String) -> ResolvedCommand<Action> {
    let disabledReason: String? =
      if let gate, !gate.isEnabled(state) { gate.hint } else { nil }
    return ResolvedCommand(
      name: name,
      argument: argument,
      help: help,
      source: source,
      disabledReason: disabledReason,
      makeAction: makeAction
    )
  }
}

extension AgentCommand where Action: Sendable {
  /// A command without an argument that always sends the same action.
  public static func action(
    _ name: String,
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ action: Action
  ) -> Self {
    Self(name: name, argument: nil, help: help, paths: paths, gate: gate, note: note) {
      (argument: String?) throws(AgentCommandError) -> Action in
      if let argument { throw .unexpectedArgument(argument) }
      return action
    }
  }

  /// A command whose argument is free text: the rest of the line, unquoted.
  public static func text(
    _ name: String,
    argument: String = "<text>",
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (String) -> Action
  ) -> Self {
    Self(name: name, argument: argument, help: help, paths: paths, gate: gate, note: note) {
      (text: String?) throws(AgentCommandError) -> Action in
      guard let text else { throw .missingArgument(argument) }
      return makeAction(text)
    }
  }

  /// A switch: the argument is `on` or `off`, e.g. `terms on`.
  public static func onOff(
    _ name: String,
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (Bool) -> Action
  ) -> Self {
    choice(name, [("on", true), ("off", false)], help: help, paths: paths, gate: gate, note: note, makeAction)
  }

  /// A command whose argument is one of a fixed set of words, each standing for a value, e.g. `filter all` for
  /// `nil` and `filter shoes` for `.shoes`.
  ///
  /// The argument is documented as `<a|b|c>` and anything else is rejected with `invalid argument: expected a|b|c`,
  /// both generated from `options` in their order, so the docs, the error and the accepted words cannot drift apart
  /// the way a hand-written `.parsing` with its own `argument:` string and error text can.
  public static func choice<Value: Sendable>(
    _ name: String,
    _ options: [(String, Value)],
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (Value) -> Action
  ) -> Self {
    let words = options.map(\.0).joined(separator: "|")
    return parsing(name, argument: "<\(words)>", help: help, paths: paths, gate: gate, note: note) {
      (text: String) throws(AgentCommandError) -> Action in
      guard let value = options.first(where: { $0.0 == text })?.1 else { throw .invalidArgument("expected \(words)") }
      return makeAction(value)
    }
  }

  /// A command whose argument is one of `options`, passed on as typed. See ``choice(_:_:help:paths:gate:note:_:)``.
  public static func choice(
    _ name: String,
    options: [String],
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (String) -> Action
  ) -> Self {
    choice(name, options.map { ($0, $0) }, help: help, paths: paths, gate: gate, note: note, makeAction)
  }

  /// A command whose argument is a case of a string enum, spelled as its raw value, offered in `allCases` order,
  /// e.g. `.choice("tab", of: Tab.self, help: "Switch tab.") { .tabSelected($0) }` documents `tab <shop|cart>`.
  public static func choice<Value: CaseIterable & RawRepresentable & Sendable>(
    _ name: String,
    of type: Value.Type,
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (Value) -> Action
  ) -> Self where Value.RawValue == String {
    choice(name, type.allCases.map { ($0.rawValue, $0) }, help: help, paths: paths, gate: gate, note: note, makeAction)
  }

  /// A command whose argument must be parsed and may be rejected.
  public static func parsing(
    _ name: String,
    argument: String,
    help: String,
    paths: [String]? = nil,
    gate: CommandGate<State>? = nil,
    note: String? = nil,
    _ makeAction: @escaping @Sendable (String) throws(AgentCommandError) -> Action
  ) -> Self {
    Self(name: name, argument: argument, help: help, paths: paths, gate: gate, note: note) {
      (text: String?) throws(AgentCommandError) -> Action in
      guard let text else { throw .missingArgument(argument) }
      return try makeAction(text)
    }
  }
}

/// A command with its enabled state already evaluated and its action lifted to some ancestor's action type.
public struct ResolvedCommand<Action>: Sendable {
  public var name: String
  public var argument: String?
  public var help: String
  /// The screen or container that contributed the command.
  public var source: String
  /// Non-nil when the command is disabled in the current state.
  public var disabledReason: String?
  public var makeAction: @Sendable (String?) throws(AgentCommandError) -> Action

  public init(
    name: String,
    argument: String?,
    help: String,
    source: String,
    disabledReason: String?,
    makeAction: @escaping @Sendable (String?) throws(AgentCommandError) -> Action
  ) {
    self.name = name
    self.argument = argument
    self.help = help
    self.source = source
    self.disabledReason = disabledReason
    self.makeAction = makeAction
  }

  public var usage: String {
    argument.map { "\(name) \($0)" } ?? name
  }

  public func map<Parent>(_ embed: @escaping @Sendable (Action) -> Parent) -> ResolvedCommand<Parent> {
    let makeAction = self.makeAction
    return ResolvedCommand<Parent>(
      name: name,
      argument: argument,
      help: help,
      source: source,
      disabledReason: disabledReason
    ) { (argument: String?) throws(AgentCommandError) -> Parent in
      embed(try makeAction(argument))
    }
  }
}

extension ResolvedCommand {
  /// `back` for when no container has anything to pop: it fails with `nothing to go back to on <path>` instead of
  /// the runner's "unknown command", which would read as if the app had no `back` at all.
  ///
  /// The root appends it last (``ActiveScreen/appendingBackFallback(source:)``), so any container that can pop
  /// shadows it, and lists ``CommandDoc/backFallback(source:)`` on every screen of its registry.
  public static func backFallback(path: String, source: String) -> Self {
    Self(name: "back", argument: nil, help: CommandDoc.backFallbackHelp, source: source, disabledReason: nil) {
      (_: String?) throws(AgentCommandError) -> Action in
      throw .notApplicable("nothing to go back to on \(path)")
    }
  }
}
