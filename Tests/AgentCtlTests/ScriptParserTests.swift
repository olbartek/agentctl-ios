import AgentCtlCore
import Testing

struct ScriptParserTests {
  @Test func separatorsCommentsAndWhitespace() throws {
    let lines = try ScriptParser.parse(
      """
      # a comment line
      login-as alice;  open 1003 ; cancel   # trailing comment

        expect screen=home/orders/1003
      """
    )
    #expect(
      lines == [
        ScriptLine(line: 2, name: "login-as", argument: "alice"),
        ScriptLine(line: 2, name: "open", argument: "1003"),
        ScriptLine(line: 2, name: "cancel", argument: nil),
        ScriptLine(line: 4, name: "expect", argument: "screen=home/orders/1003"),
      ]
    )
  }

  @Test func quotesProtectSeparatorsAndAreKept() throws {
    let lines = try ScriptParser.parse(#"password "a;b#c" ; name Alice Smith; expect name="Alice \"A\" Smith""#)
    #expect(lines.map(\.name) == ["password", "name", "expect"])
    #expect(lines[0].argument == #""a;b#c""#)
    #expect(lines[1].argument == "Alice Smith")
    #expect(lines[2].argument == #"name="Alice \"A\" Smith""#)
  }

  @Test func unterminatedQuoteIsAnError() {
    #expect(throws: ScriptError(line: 2, column: 7, message: "unterminated quote")) {
      try ScriptParser.parse("submit\nemail \"alice")
    }
    #expect(throws: ScriptError.self) {
      try ScriptParser.parse("email \"alice\nsubmit\"")
    }
  }

  @Test func emptyScripts() throws {
    #expect(try ScriptParser.parse("") == [])
    #expect(try ScriptParser.parse(" ; ;\n# only a comment\n") == [])
  }

  @Test func argumentText() {
    #expect(ArgumentText.unquoted(#""a;b#c""#) == "a;b#c")
    #expect(ArgumentText.unquoted("Alice Smith") == "Alice Smith")
    #expect(ArgumentText.unquoted(#""a" "b""#) == #""a" "b""#)
    #expect(ArgumentText.unquoted(#""say \"hi\"""#) == #"say "hi""#)
    #expect(ArgumentText.tokens(#"screen=x name="Alice Smith"  error=none"#) == ["screen=x", "name=Alice Smith", "error=none"])
    #expect(ArgumentText.tokens(#"a="""#) == ["a="])
  }

  @Test func durations() {
    #expect(ScriptParser.parseDuration("500ms") == .milliseconds(500))
    #expect(ScriptParser.parseDuration("30s") == .seconds(30))
    #expect(ScriptParser.parseDuration("5m") == .seconds(300))
    #expect(ScriptParser.parseDuration("1h") == .seconds(3600))
    #expect(ScriptParser.parseDuration("s") == nil)
    #expect(ScriptParser.parseDuration("1.5s") == nil)
    #expect(ScriptParser.parseDuration("10") == nil)
    #expect(ScriptParser.parseDuration("-1s") == nil)
  }

  /// `9999999999999999h` fits in an `Int` but not once converted to seconds; it used to trap in the conversion,
  /// crashing the CLI (exit 133) and, through `app run`, the app. A number too large for an `Int` at all was
  /// already rejected.
  @Test func durationsTooLargeToRepresentAreRejected() {
    #expect(ScriptParser.parseDuration("9999999999999999h") == nil)
    #expect(ScriptParser.parseDuration("9223372036854775807m") == nil)
    #expect(ScriptParser.parseDuration("99999999999999999999s") == nil)
    // The largest values that do fit are still accepted.
    #expect(ScriptParser.parseDuration("\(Int.max)s") == .seconds(Int.max))
    #expect(ScriptParser.parseDuration("\(Int.max / 3600)h") == .seconds(Int.max / 3600 * 3600))
    #expect(ScriptParser.parseDuration("\(Int.max)ms") == .milliseconds(Int.max))
  }
}
