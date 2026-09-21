import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation
import Testing

/// Reads every dependency `HeadlessHost` pins into its state, where a test can see them.
@Reducer
struct Probe {
  @ObservableState
  struct State: Equatable {
    var timeZone = TimeZone.current
    var locale = ""
    var calendar = ""
    var calendarTimeZone = TimeZone.current
    var date = Date.distantPast
    var uuids: [UUID] = []
    var randomNumbers: [Int] = []
  }

  enum Action: Sendable {
    case read
  }

  @Dependency(\.timeZone) var timeZone
  @Dependency(\.locale) var locale
  @Dependency(\.calendar) var calendar
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  var body: some ReducerOf<Self> {
    Reduce { state, _ in
      state.timeZone = timeZone
      state.locale = locale.identifier
      state.calendar = "\(calendar.identifier)"
      state.calendarTimeZone = calendar.timeZone
      state.date = now
      state.uuids = [uuid(), uuid()]
      state.randomNumbers = withRandomNumberGenerator { generator in
        (0..<3).map { _ in Int.random(in: 0..<1_000_000, using: &generator) }
      }
      return .none
    }
  }
}

extension Probe: AgentScreen, AgentContainer {
  static let screenPaths = ["probe"]
  static func screenPath(_ state: State) -> String { "probe" }
  static let summaryKeys: [String] = []
  static func summary(_ state: State) -> [SummaryItem] { [] }
  static let commands: [AgentCommand<State, Action>] = []
  static var registry: [ScreenDoc] { screenDocs }
}

/// What this guards: the dependencies a headless run pins (CONTRACT.md §6, and the table on `HeadlessHost`), so
/// that a reducer reading the time zone, the locale, the calendar or a random number prints the same step on
/// every machine — and that a host's `configure` closure, which runs last, can still override any of them.
@MainActor
@Suite
struct HeadlessPinsTests {
  func read(configure: @escaping (inout DependencyValues, HeadlessEnvironment) -> Void = { _, _ in }) -> Probe.State {
    let host = HeadlessHost(
      initialState: { Probe.State() }, reducer: { Probe() }, mockMethods: [], configure: configure
    )
    host.store.send(.read)
    return host.store.state
  }

  @Test func theHeadlessHostPinsTimeLocaleAndRandomness() {
    let state = read()
    // UTC, which Foundation spells `GMT`: no offset, and no daylight saving time to change it.
    for timeZone in [state.timeZone, state.calendarTimeZone] {
      #expect(timeZone == HeadlessHost<Probe>.fixedTimeZone)
      #expect(timeZone.secondsFromGMT(for: HeadlessHost<Probe>.fixedDate) == 0)
      #expect(timeZone.nextDaylightSavingTimeTransition(after: HeadlessHost<Probe>.fixedDate) == nil)
    }
    #expect(state.locale == "en_US_POSIX")
    #expect(state.calendar == "gregorian")
    #expect(state.date == HeadlessHost<Probe>.fixedDate)
    #expect(state.uuids.map(\.uuidString) == [
      "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-000000000001",
    ])
  }

  /// A fresh host draws the same numbers — the generator is seeded, not the system's.
  @Test func randomNumbersRepeatAcrossHosts() {
    let first = read().randomNumbers
    #expect(first.count == 3)
    #expect(read().randomNumbers == first)
    #expect(Set(first).count > 1, "a seeded generator that returns one value is not much of a generator: \(first)")
  }

  @Test func configureRunsLastAndOverrides() {
    let state = read { deps, _ in
      deps.locale = Locale(identifier: "fr_FR")
      deps.timeZone = TimeZone(identifier: "Europe/Warsaw") ?? .current
    }
    #expect(state.locale == "fr_FR")
    #expect(state.timeZone.identifier == "Europe/Warsaw")
    // What it leaves alone stays pinned.
    #expect(state.calendarTimeZone == HeadlessHost<Probe>.fixedTimeZone)
  }
}
