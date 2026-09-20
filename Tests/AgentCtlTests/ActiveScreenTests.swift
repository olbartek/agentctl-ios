import AgentCtlCore
import ComposableArchitecture
import Testing

@Reducer
struct Note {
  @ObservableState
  struct State: Equatable {
    var text = ""
    var saved = false
    var canSave: Bool { !text.isEmpty }
  }

  enum Action: Equatable, Sendable {
    case textChanged(String)
    case saveTapped
    case appeared
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .textChanged(text):
        state.text = text
      case .saveTapped:
        state.saved = true
      case .appeared:
        break
      }
      return .none
    }
  }
}

extension Note: AgentScreen {
  static let screenPaths = ["notes/edit", "notes/saved"]
  static func screenPath(_ state: State) -> String { state.saved ? "notes/saved" : "notes/edit" }
  static let summaryKeys = ["text", "canSave"]
  static func summary(_ state: State) -> [SummaryItem] {
    [SummaryItem("text", state.text), SummaryItem("canSave", state.canSave)]
  }
  static let onAppear: Action? = .appeared
  static let commands: [AgentCommand<State, Action>] = [
    .text("text", help: "Set the text", paths: ["notes/edit"]) { .textChanged($0) },
    .action(
      "save",
      help: "Save the note",
      paths: ["notes/edit"],
      gate: CommandGate(hint: "canSave=false") { $0.canSave },
      .saveTapped
    ),
    .parsing("pick", argument: "<a|b>", help: "Pick a or b") { text throws(AgentCommandError) in
      guard ["a", "b"].contains(text) else { throw .invalidArgument("expected a|b") }
      return .textChanged(text)
    },
  ]
}

@Reducer
struct Notebook {
  @ObservableState
  struct State: Equatable {
    var root = Note.State()
    var path = StackState<Note.State>()
  }

  enum Action: Equatable, Sendable {
    case root(Note.Action)
    case path(StackActionOf<Note>)
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.root, action: \.root) { Note() }
    Reduce { _, _ in .none }
      .forEach(\.path, action: \.path) { Note() }
  }
}

extension Notebook: AgentContainer {
  static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    var commands: [ResolvedCommand<Action>] = []
    if let id = state.path.ids.last {
      commands.append(
        AgentCommand<State, Action>.action("back", help: "Pop", .path(.popFrom(id: id)))
          .resolve(state, source: "Notebook")
      )
    }
    if let id = state.path.ids.last, let top = state.path[id: id] {
      return Note.activeScreen(top)
        .map { .path(.element(id: id, action: $0)) }
        .identified(by: id.debugDescription)
        .appending(commands)
    }
    return Note.activeScreen(state.root).map { .root($0) }.appending(commands)
  }

  static var registry: [ScreenDoc] { Note.screenDocs }
}

struct ActiveScreenTests {
  @Test func leafResolutionFiltersByPathAndEvaluatesGates() throws {
    let screen = Note.activeScreen(Note.State())
    #expect(screen.path == "notes/edit")
    #expect(screen.commands.map(\.name) == ["text", "save", "pick"])
    #expect(screen.command(named: "save")?.disabledReason == "canSave=false")
    #expect(screen.appearAction == .appeared)
    #expect(screen.summary == [SummaryItem("text", ""), SummaryItem("canSave", false)])

    let saved = Note.activeScreen(Note.State(text: "x", saved: true))
    #expect(saved.path == "notes/saved")
    #expect(saved.commands.map(\.name) == ["pick"])
  }

  @Test func argumentHandling() throws {
    let screen = Note.activeScreen(Note.State())
    #expect(try screen.command(named: "text")?.makeAction("hello") == .textChanged("hello"))
    #expect(throws: AgentCommandError.missingArgument("<text>")) { try screen.command(named: "text")?.makeAction(nil) }
    #expect(throws: AgentCommandError.unexpectedArgument("now")) { try screen.command(named: "save")?.makeAction("now") }
    #expect(throws: AgentCommandError.invalidArgument("expected a|b")) { try screen.command(named: "pick")?.makeAction("c") }
  }

  @Test func onOffCommands() throws {
    let command = AgentCommand<Note.State, Note.Action>
      .onOff("saved", help: "Save or clear") { $0 ? .saveTapped : .textChanged("") }
      .resolve(Note.State(), source: "Note")
    #expect(command.argument == "<on|off>")
    #expect(try command.makeAction("on") == .saveTapped)
    #expect(try command.makeAction("off") == .textChanged(""))
    #expect(throws: AgentCommandError.invalidArgument("expected on|off")) { try command.makeAction("yes") }
    #expect(throws: AgentCommandError.missingArgument("<on|off>")) { try command.makeAction(nil) }
  }

  @Test func containerLiftsStackElementActions() throws {
    var state = Notebook.State()
    #expect(Notebook.activeScreen(state).commands.map(\.name) == ["text", "save", "pick"])
    #expect(try Notebook.activeScreen(state).command(named: "text")?.makeAction("x") == .root(.textChanged("x")))

    state.path.append(Note.State(text: "pushed"))
    let id = try #require(state.path.ids.last)
    let screen = Notebook.activeScreen(state)
    #expect(screen.identity == "\(id.debugDescription)/notes/edit")
    #expect(screen.commands.map(\.name) == ["text", "save", "pick", "back"])
    #expect(try screen.command(named: "save")?.makeAction(nil) == .path(.element(id: id, action: .saveTapped)))
    #expect(try screen.command(named: "back")?.makeAction(nil) == .path(.popFrom(id: id)))
    #expect(screen.appearAction == .path(.element(id: id, action: .appeared)))
  }

  @Test func docs() {
    let docs = Notebook.registry
    #expect(docs.map(\.path) == ["notes/edit", "notes/saved"])
    #expect(docs[0].commands.map(\.usage) == ["text <text>", "save", "pick <a|b>"])
    #expect(docs[0].commands[1].note == "disabled when canSave=false")
    #expect(docs[1].commands.map(\.name) == ["pick"])
    let inherited = docs[0].inheriting([CommandDoc(name: "back", argument: nil, help: "Pop", source: "Notebook")])
    #expect(inherited.commands.map(\.name) == ["text", "save", "pick", "back"])
  }
}
