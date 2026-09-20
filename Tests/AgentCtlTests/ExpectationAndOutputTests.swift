import AgentCtlCore
import Testing

struct ExpectationTests {
  let snapshot = StepSnapshot(
    screen: "auth/otp/code",
    summary: [SummaryItem("email", "alice@example.com"), SummaryItem("resendIn", 29), SummaryItem("name", "Alice Smith")],
    calls: ["auth.sendOTP"],
    error: nil,
    pending: 1
  )

  @Test func parsesPairs() throws {
    let expectation = try Expectation.parse(#"screen=auth/login name="Alice Smith" call=auth.login"#)
    #expect(
      expectation.pairs == [
        .init("screen", "auth/login"), .init("name", "Alice Smith"), .init("call", "auth.login"),
      ]
    )
  }

  @Test func rejectsMalformedArguments() {
    #expect(throws: ExpectationSyntaxError.self) { try Expectation.parse(nil) }
    #expect(throws: ExpectationSyntaxError.self) { try Expectation.parse("screen") }
    #expect(throws: ExpectationSyntaxError.self) { try Expectation.parse("=value") }
  }

  @Test func passingExpectation() throws {
    let expectation = try Expectation.parse(
      #"screen=auth/otp/code resendIn=29 name="Alice Smith" call=auth.sendOTP error=none pending=1"#
    )
    #expect(expectation.evaluate(snapshot) == [])
  }

  @Test func failureMessages() throws {
    let expectation = try Expectation.parse("screen=auth/login resendIn=30 call=auth.login error=invalidCode pending=0 nope=1")
    #expect(
      expectation.evaluate(snapshot) == [
        "expected screen=auth/login, got screen=auth/otp/code",
        "expected resendIn=30, got resendIn=29",
        "expected call=auth.login, got calls=auth.sendOTP",
        "expected error=invalidCode, got error=none",
        "expected pending=0, got pending=1",
        "unknown key 'nope' on auth/otp/code; available: screen, call, error, pending, email, resendIn, name",
      ]
    )
  }

  @Test func callWithNoCalls() throws {
    var quiet = snapshot
    quiet.calls = []
    #expect(try Expectation.parse("call=auth.login").evaluate(quiet) == ["expected call=auth.login, got calls=none"])
  }
}

struct StepFormatterTests {
  @Test func textMatchesSpec() {
    let step = StepRecord(
      command: "submit",
      screen: "home/orders",
      summary: [SummaryItem("orders", 3), SummaryItem("loading", false)],
      calls: ["auth.login", "session.save", "orders.fetchOrders"],
      error: nil,
      pending: 0
    )
    #expect(
      StepFormatter.text(step) == """
        > submit
          screen=home/orders orders=3 loading=false calls=auth.login,session.save,orders.fetchOrders
        """
    )
  }

  @Test func textWithErrorPendingFailureAndQuoting() {
    let step = StepRecord(
      command: "expect resendIn=30",
      screen: "auth/otp/code",
      summary: [SummaryItem("name", "Alice Smith"), SummaryItem("resendIn", 29)],
      calls: [],
      error: "resendNotAvailable",
      pending: 1,
      settled: false,
      ok: false,
      message: "expected resendIn=30, got resendIn=29"
    )
    #expect(
      StepFormatter.text(step) == """
        > expect resendIn=30
          screen=auth/otp/code name="Alice Smith" resendIn=29 error=resendNotAvailable pending=1 settled=false
          FAIL expected resendIn=30, got resendIn=29
        """
    )
  }

  @Test func json() {
    let step = StepRecord(
      command: "open 1003",
      screen: "home/orders/1003",
      summary: [SummaryItem("status", "pending")],
      calls: ["orders.fetchOrder"],
      error: nil,
      pending: 0
    )
    #expect(
      StepFormatter.json([step]) == """
        [
          {
            "calls" : [
              "orders.fetchOrder"
            ],
            "command" : "open 1003",
            "error" : null,
            "ok" : true,
            "pending" : 0,
            "screen" : "home/orders/1003",
            "settled" : true,
            "summary" : {
              "status" : "pending"
            }
          }
        ]
        """
    )
  }
}
