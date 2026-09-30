import AgentCtlBridge
import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation
import Testing
import TinyApp

/// A root container with everything the 0.5 helpers are for: a stack of ``Note``s with its own `back`, a command it
/// offers on every screen beneath it (`mode`, an enum choice), one it offers on one path only (`clear`), and the
/// `back` fallback for when nothing is pushed.
@Reducer
struct Desk {
  enum Mode: String, CaseIterable, Equatable, Sendable {
    case calm
    case busy
  }

  @ObservableState
  struct State: Equatable {
    var root = Note.State()
    var path = StackState<Note.State>()
    var mode = Mode.calm
  }

  enum Action: Equatable, Sendable {
    case root(Note.Action)
    case path(StackActionOf<Note>)
    case modeSet(Mode)
    case cleared
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.root, action: \.root) { Note() }
    Reduce { state, action in
      switch action {
      case let .modeSet(mode):
        state.mode = mode
      case .cleared:
        state.root = Note.State()
      case .root, .path:
        break
      }
      return .none
    }
    .forEach(\.path, action: \.path) { Note() }
  }
}

extension Desk: AgentContainer {
  static let inheritedCommands: [AgentCommand<State, Action>] = [
    .choice("mode", of: Mode.self, help: "Set the mode") { .modeSet($0) },
    .action("clear", help: "Start a new note", paths: ["notes/saved"], .cleared),
  ]

  /// Resolves `back` before the inherited commands on purpose: they must still come first.
  static func activeScreen(_ state: State) -> ActiveScreen<Action> {
    guard let id = state.path.ids.last, let top = state.path[id: id] else {
      return inheritingCommands(Note.activeScreen(state.root).map { .root($0) }, state)
        .appendingBackFallback(source: containerName)
    }
    let back = AgentCommand<State, Action>.action("back", help: "Pop", .path(.popFrom(id: id)))
      .resolve(state, source: containerName)
    let child = Note.activeScreen(top).map { Action.path(.element(id: id, action: $0)) }.identified(by: "\(id)")
    return inheritingCommands(child.appending([back]), state).appendingBackFallback(source: containerName)
  }

  static var registry: [ScreenDoc] {
    let back = CommandDoc(name: "back", argument: nil, help: "Pop", source: containerName)
    return inheritingCommands(Note.screenDocs.map { $0.inheriting([back]) })
      .map { $0.inheriting([.backFallback(source: containerName)]) }
  }

  @MainActor
  static func makeRunner(mockMethods: [MockMethod] = []) -> ScriptRunner<Desk> {
    let callLog = MockCallLog()
    let tracker = EffectTracker()
    let store = Store(initialState: State()) { TrackingReducer(tracker: tracker, base: Desk()) }
    return ScriptRunner(
      store: store,
      callLog: callLog,
      faults: MockFaults(),
      tracker: tracker,
      pending: { 0 },
      environment: RunnerEnvironment(
        settle: { await settleHeadless(state: { store.state }, callLog: callLog, tracker: tracker, pending: { 0 }) },
        advance: nil,
        synthesizesAppearance: true
      ),
      mockMethods: mockMethods
    )
  }
}

/// What this guards: the 0.5 helpers (`.choice`, `backFallback`, inherited container commands, common mock codes,
/// `AgentLaunch.isRequested`). Their texts are shared with agentctl-android byte for byte.
struct HelpersTests {
  enum Size: String, CaseIterable, Sendable {
    case small
    case large
  }

  @Test func choiceDocumentsAndRejectsFromItsOptions() throws {
    let command = AgentCommand<Note.State, Note.Action>
      .choice("size", of: Size.self, help: "Pick a size") { .textChanged($0.rawValue) }
      .resolve(Note.State(), source: "Note")
    #expect(command.usage == "size <small|large>")
    #expect(try command.makeAction("large") == .textChanged("large"))
    #expect(throws: AgentCommandError.invalidArgument("expected small|large")) { try command.makeAction("medium") }
    #expect(throws: AgentCommandError.missingArgument("<small|large>")) { try command.makeAction(nil) }
    let message = AgentCommandError.invalidArgument("expected small|large").message
    #expect(message == "invalid argument: expected small|large")
  }

  @Test func choiceWithPairsAndPlainWords() throws {
    let filter = AgentCommand<Note.State, Note.Action>
      .choice("filter", [("all", nil), ("small", Size.small)], help: "Filter") { .textChanged($0?.rawValue ?? "-") }
      .doc(source: "Note")
    #expect(filter.usage == "filter <all|small>")
    let words = AgentCommand<Note.State, Note.Action>
      .choice("pick", options: ["a", "b"], help: "Pick a or b") { .textChanged($0) }
      .resolve(Note.State(), source: "Note")
    #expect(words.argument == "<a|b>")
    #expect(try words.makeAction("b") == .textChanged("b"))
    // Exact words only: no trimming, no case folding.
    #expect(throws: AgentCommandError.invalidArgument("expected a|b")) { try words.makeAction("A") }
  }

  @Test func inheritedCommandsGoBeforeTheContainersOwnWhateverTheOrder() throws {
    var state = Desk.State()
    #expect(Desk.activeScreen(state).commands.map(\.name) == ["text", "save", "pick", "mode", "back"])
    #expect(Desk.activeScreen(state).commands.map(\.source) == ["Note", "Note", "Note", "Desk", "Desk"])
    #expect(try Desk.activeScreen(state).command(named: "mode")?.makeAction("busy") == .modeSet(.busy))

    state.path.append(Note.State(text: "x", saved: true))
    let screen = Desk.activeScreen(state)
    #expect(screen.path == "notes/saved")
    #expect(screen.commands.map(\.name) == ["pick", "mode", "clear", "back"])
    let id = try #require(state.path.ids.last)
    #expect(try screen.command(named: "back")?.makeAction(nil) == .path(.popFrom(id: id)))
  }

  @Test func theRegistryListsInheritedCommandsWhereTheActiveScreenHasThem() {
    let docs = Desk.registry
    #expect(docs.map(\.path) == ["notes/edit", "notes/saved"])
    #expect(docs[0].commands.map(\.usage) == ["text <text>", "save", "pick <a|b>", "mode <calm|busy>", "back"])
    #expect(docs[1].commands.map(\.usage) == ["pick <a|b>", "mode <calm|busy>", "clear", "back"])
    #expect(docs[1].commands.map(\.source) == ["Note", "Desk", "Desk", "Desk"])
    #expect(docs[1].commands.last?.help == "Pop")
  }

  @Test func aDescendantShadowsAnInheritedCommand() {
    struct Shadowing: AgentContainer {
      static let inheritedCommands: [AgentCommand<Note.State, Note.Action>] = [
        .action("pick", help: "Shadowed", .saveTapped)
      ]
      static func activeScreen(_ state: Note.State) -> ActiveScreen<Note.Action> {
        inheritingCommands(Note.activeScreen(state), state)
      }
      static var registry: [ScreenDoc] { inheritingCommands(Note.screenDocs) }
    }
    #expect(Shadowing.activeScreen(Note.State()).command(named: "pick")?.source == "Note")
    #expect(Shadowing.registry[0].commands.filter { $0.name == "pick" }.map(\.help) == ["Pick a or b"])
  }

  @Test func theBackFallbackFailsNamingThePath() {
    let back = ResolvedCommand<Note.Action>.backFallback(path: "home/shop", source: "Root")
    #expect(back.name == "back" && back.argument == nil && back.disabledReason == nil)
    #expect(throws: AgentCommandError.notApplicable("nothing to go back to on home/shop")) { try back.makeAction(nil) }
    let help = "Fails with 'nothing to go back to' when no screen is pushed."
    #expect(CommandDoc.backFallback(source: "Root") == CommandDoc(name: "back", argument: nil, help: help, source: "Root"))
  }

  @Test func commonMockCodesFollowEachMethodsOwn() {
    let methods = [
      MockMethod("auth.signIn", errorCodes: ["invalidCredentials", "locked"]),
      MockMethod("auth.refresh", errorCodes: ["network", "expired"]),
      MockMethod("auth.signOut", errorCodes: []),
    ].accepting(["network", "timeout"])
    #expect(methods.map(\.errorCodes) == [
      ["invalidCredentials", "locked", "network", "timeout"],
      ["network", "expired", "timeout"],
      ["network", "timeout"],
    ])
    #expect(MockMethod("a.b", errorCodes: ["x"]).accepting(["x"]) == MockMethod("a.b", errorCodes: ["x"]))
  }

  #if DEBUG
    @Test func theBridgeIsRequestedByAnAgentPort() {
      #expect(AgentLaunch<TinyRoot>.isRequested(["/path/App", "-agent-port", "8799"]))
      #expect(AgentLaunch<TinyRoot>.isRequested(["/path/App", "-agent-port"]))
      #expect(!AgentLaunch<TinyRoot>.isRequested(["/path/App"]))
      // Seeding or latency alone is not an opt-in: only `app launch` passes `-agent-port`, and it always does.
      #expect(!AgentLaunch<TinyRoot>.isRequested(["/path/App", "-appctl-seed", "open 1", "-mock-latency", "0"]))
      #expect(!AgentLaunch<TinyRoot>.isRequested(["/path/App", "-agent-port=8799"]))
    }
  #endif
}

extension AgentCtlSuite {
  /// The helpers' texts as a script sees them: the failed step's message, which is what an agent reads.
  @MainActor
  @Suite struct HelpersScriptTests {
    func failure(_ script: String, mockMethods: [MockMethod] = []) async -> String? {
      await serially {
        let runner = Desk.makeRunner(mockMethods: mockMethods)
        _ = await runner.launch()
        return await runner.run(script).steps.last?.message
      }
    }

    @Test func aWrongChoiceNamesTheOptions() async {
      #expect(await failure("mode frantic") == "mode <calm|busy>: invalid argument: expected calm|busy")
      #expect(await failure("mode") == "mode <calm|busy>: missing argument: expected <calm|busy>")
    }

    @Test func backWithNothingPushedSaysSo() async {
      #expect(await failure("back") == "back: nothing to go back to on notes/edit")
    }

    @Test func aCommonCodeIsAcceptedAndListedAfterTheMethodsOwn() async {
      let methods = [MockMethod("notes.save", errorCodes: ["full"])].accepting(["network"])
      #expect(await failure("mock notes.save network; mock notes.save x", mockMethods: methods)
        == "unknown error 'x' for notes.save; valid: full, network")
    }
  }
}
