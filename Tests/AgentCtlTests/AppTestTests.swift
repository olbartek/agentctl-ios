#if os(macOS)
  import AgentCtlCore
  import Foundation
  import Testing

  @testable import AgentCtlCLI

  /// What this guards: `app test`'s own logic (issue #2) — which files it skips, how it reads a run through the
  /// bridge into PASS, FAIL or SKIP, and the lines it prints.
  ///
  /// What it does not guard: launching the app and talking to its bridge, which need a simulator.
  @MainActor
  @Suite
  struct AppTestTests {
    @Test
    func aSkipMarkerGivesItsReason() {
      #expect(AppTestSkip.reason(in: "# app-test: skip checks the launch's calls\nexpect screen=items") == "checks the launch's calls")
      #expect(AppTestSkip.reason(in: "open 2\n  #  app-test:  skip   the date is fixed only headlessly") == "the date is fixed only headlessly")
      #expect(AppTestSkip.reason(in: "# appctl-sim: skip from the old script") == "from the old script")
      #expect(AppTestSkip.reason(in: "# app-test: skip") == "no reason given")
    }

    @Test
    func noMarkerNoSkip() {
      #expect(AppTestSkip.reason(in: "# Logging in with a code.\nopen 2") == nil)
      #expect(AppTestSkip.reason(in: "# app-test: skipping ahead") == nil)
      #expect(AppTestSkip.reason(in: "open 2 # app-test: skip not a comment line") == nil)
    }

    let lines = [
      ScriptLine(line: 2, name: "open", argument: "2"),
      ScriptLine(line: 3, name: "save", argument: nil),
      ScriptLine(line: 5, name: "expect", argument: "saved=false"),
    ]

    @Test
    func aRunThatExitsZeroPassesWithItsStepCount() {
      let body = """
        > open 2
          screen=items/2 title="Second item" saved=false cooldown=0
        > save
          screen=items/2 title="Second item" saved=true cooldown=3 pending=1

        """
      let result = AppTest.result(name: "save", lines: lines, body: body, exitCode: 0, duration: .milliseconds(1234))
      #expect(result.report == "PASS save (2 steps, 1234 ms)")
    }

    @Test
    func aFailureNamesTheScriptLineAndShowsTheFailingStep() {
      let body = """
        > open 2
          screen=items/2 title="Second item" saved=false cooldown=0
        > save
          screen=items/2 title="Second item" saved=true cooldown=3 pending=1
        > expect saved=false
          screen=items/2 title="Second item" saved=true cooldown=3 pending=1
          FAIL expected saved=false, got saved=true

        """
      let result = AppTest.result(name: "save", lines: lines, body: body, exitCode: 1, duration: .seconds(2))
      #expect(result.failed)
      #expect(result.report == """
        FAIL save:5
          > expect saved=false
            screen=items/2 title="Second item" saved=true cooldown=3 pending=1
            FAIL expected saved=false, got saved=true
        """)
    }

    @Test
    func aParseErrorFromTheBridgeFails() {
      let result = AppTest.result(
        name: "broken", lines: lines, body: "error: parse error: line 1, column 8: unterminated quote\n", exitCode: 2,
        duration: .zero
      )
      #expect(result.report == "FAIL broken\n  error: parse error: line 1, column 8: unterminated quote")
    }

    @Test
    func theSummaryCountsSkipsApart() {
      let results = [
        AppTest.Result(name: "a", outcome: .passed(steps: 3, duration: .seconds(1))),
        AppTest.Result(name: "b", outcome: .failed(line: 2, text: "> x")),
        AppTest.Result(name: "c", outcome: .skipped("real time")),
        AppTest.Result(name: "d", outcome: .broken("launch failed")),
      ]
      #expect(AppTest.summary(results) == "1 passed, 2 failed, 1 skipped")
      #expect(results[2].report == "SKIP c: real time")
      #expect(results[3].report == "FAIL d\n  launch failed")
    }

    @Test
    func chapterTimestamps() {
      #expect(AppTest.timestamp(.seconds(0)) == "00:00:00")
      #expect(AppTest.timestamp(.milliseconds(61_900)) == "00:01:01")
      #expect(AppTest.timestamp(.seconds(3 * 3600 + 25 * 60 + 7)) == "03:25:07")
    }
  }
#endif
