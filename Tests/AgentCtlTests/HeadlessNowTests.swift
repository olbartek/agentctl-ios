import AgentCtlCore
import AgentCtlTCA
import ComposableArchitecture
import Foundation
import Testing

/// Records the date a reducer reads, and shows the date its summary reads, so a test can compare the two.
@Reducer
struct DateReader {
  @ObservableState
  struct State: Equatable {
    var readAt: Date?
  }

  enum Action: Sendable {
    case read
  }

  @Dependency(\.date.now) var now

  var body: some ReducerOf<Self> {
    Reduce { state, _ in
      state.readAt = now
      return .none
    }
  }
}

extension DateReader: AgentScreen, AgentContainer {
  static let screenPaths = ["clock"]
  static func screenPath(_ state: State) -> String { "clock" }
  static let summaryKeys = ["reducer", "summary"]

  static func summary(_ state: State) -> [SummaryItem] {
    // A summary that applies a date rule reads `\.date` itself, outside any reducer.
    @Dependency(\.date.now) var now
    return [
      SummaryItem("reducer", state.readAt.map(format) ?? "none"),
      SummaryItem("summary", format(now)),
    ]
  }

  static func format(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  static let commands: [AgentCommand<State, Action>] = [.action("read", help: "Read the date.", .read)]
  static var registry: [ScreenDoc] { screenDocs }
}

extension AgentCtlSuite {
  /// What this guards: headless "now" (CONTRACT.md §6). The app's `\.date` starts at the fixed date and moves with
  /// `advance`, and a step's summary is computed in the store's dependency context, so it reads the same date as the
  /// reducers — before and after an `advance` — whatever the ambient context is (the real clock in the CLI, an
  /// unimplemented one in a test).
  @MainActor
  @Suite struct HeadlessNowTests {
    @Test func theDateMovesWithAdvanceAndSummariesReadTheStoresDate() async {
      let output = await serially {
        let host = HeadlessHost(
          initialState: { DateReader.State() }, reducer: { DateReader() }, mockMethods: [], configure: { _, _ in }
        )
        let runner = host.makeRunner()
        _ = await runner.launch()
        return StepFormatter.text(await runner.run("read; advance 90s; read").steps)
      }
      #expect(
        output == """
          > read
            screen=clock reducer=2026-01-01T09:00:00Z summary=2026-01-01T09:00:00Z
          > advance 90s
            screen=clock reducer=2026-01-01T09:00:00Z summary=2026-01-01T09:01:30Z
          > read
            screen=clock reducer=2026-01-01T09:01:30Z summary=2026-01-01T09:01:30Z
          """
      )
    }

    @Test func theEnvironmentsNowIsTheAppsDate() async {
      var now: (@Sendable () -> Date)?
      let host = HeadlessHost(
        initialState: { DateReader.State() }, reducer: { DateReader() }, mockMethods: [],
        configure: { _, environment in now = environment.now }
      )
      #expect(now?() == HeadlessHost<DateReader>.fixedDate)
      await host.clock.advance(by: .seconds(3600))
      #expect(now?() == HeadlessHost<DateReader>.fixedDate.addingTimeInterval(3600))
    }
  }
}
