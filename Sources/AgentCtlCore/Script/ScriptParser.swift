/// One command in a script: `name` plus the raw argument text (quotes preserved).
public struct ScriptLine: Equatable, Sendable {
  /// 1-based line number in the source.
  public var line: Int
  public var name: String
  /// The rest of the command after the name, trimmed, with quotes preserved. `nil` if empty.
  public var argument: String?

  public init(line: Int, name: String, argument: String?) {
    self.line = line
    self.name = name
    self.argument = argument
  }

  /// The command as written, normalized to `name argument`.
  public var text: String {
    argument.map { "\(name) \($0)" } ?? name
  }
}

/// A syntax error in a script. Maps to exit code 2.
public struct ScriptError: Error, Equatable, Sendable {
  public var line: Int
  public var column: Int
  public var message: String

  public init(line: Int, column: Int, message: String) {
    self.line = line
    self.column = column
    self.message = message
  }

  public var description: String { "line \(line), column \(column): \(message)" }
}

/// Parses the script language shared by `appctl run`, scenarios, `-appctl-seed` and AgentBridge.
///
/// - Commands are separated by `;` or newlines.
/// - `#` starts a comment that runs to the end of the line.
/// - Double quotes protect `;` and `#`; inside quotes `\"` and `\\` are escapes. Quotes are kept in the
///   argument so that commands like `expect` can split on unquoted spaces; use ``ArgumentText`` to unquote.
public enum ScriptParser {
  public static func parse(_ source: String) throws(ScriptError) -> [ScriptLine] {
    var result: [ScriptLine] = []
    var current = ""
    var currentLine = 1
    var line = 1
    var column = 0
    var inQuotes = false
    var quoteStart = (line: 0, column: 0)
    var escaping = false
    var inComment = false

    func flush() {
      let trimmed = current.trimmingWhitespace()
      if !trimmed.isEmpty {
        let name = String(trimmed.prefix { !$0.isWhitespace })
        let rest = trimmed.dropFirst(name.count).trimmingWhitespace()
        result.append(ScriptLine(line: currentLine, name: name, argument: rest.isEmpty ? nil : rest))
      }
      current = ""
    }

    for character in source {
      column += 1
      if character == "\n" {
        if inQuotes {
          throw ScriptError(line: quoteStart.line, column: quoteStart.column, message: "unterminated quote")
        }
        inComment = false
        flush()
        line += 1
        column = 0
        currentLine = line
        continue
      }
      if inComment { continue }
      if inQuotes {
        current.append(character)
        if escaping {
          escaping = false
        } else if character == "\\" {
          escaping = true
        } else if character == "\"" {
          inQuotes = false
        }
        continue
      }
      switch character {
      case "\"":
        inQuotes = true
        quoteStart = (line, column)
        current.append(character)
      case "#":
        inComment = true
      case ";":
        flush()
        currentLine = line
      default:
        if current.trimmingWhitespace().isEmpty { currentLine = line }
        current.append(character)
      }
    }
    if inQuotes {
      throw ScriptError(line: quoteStart.line, column: quoteStart.column, message: "unterminated quote")
    }
    flush()
    return result
  }
}

/// Helpers for argument text that may contain double-quoted parts.
public enum ArgumentText {
  /// Removes surrounding quotes and resolves escapes when the whole argument is one quoted string.
  /// `"a;b"` → `a;b`, `Alice Smith` → `Alice Smith`.
  public static func unquoted(_ text: String) -> String {
    guard text.count >= 2, text.first == "\"", text.last == "\"" else { return text }
    let tokens = self.tokens(text)
    return tokens.count == 1 ? tokens[0] : text
  }

  /// Splits on unquoted whitespace, then removes quotes and resolves escapes in each token.
  /// `name="Alice Smith" email=a` → `["name=Alice Smith", "email=a"]`.
  public static func tokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var hasToken = false
    var inQuotes = false
    var escaping = false
    for character in text {
      if inQuotes {
        if escaping {
          current.append(character)
          escaping = false
        } else if character == "\\" {
          escaping = true
        } else if character == "\"" {
          inQuotes = false
        } else {
          current.append(character)
        }
      } else if character == "\"" {
        inQuotes = true
        hasToken = true
      } else if character.isWhitespace {
        if hasToken { tokens.append(current) }
        current = ""
        hasToken = false
      } else {
        current.append(character)
        hasToken = true
      }
    }
    if hasToken { tokens.append(current) }
    return tokens
  }
}

/// Parses durations such as `500ms`, `30s`, `5m`, `1h`.
public func parseDuration(_ text: String) -> Duration? {
  let units: [(suffix: String, make: (Int) -> Duration)] = [
    ("ms", { .milliseconds($0) }),
    ("s", { .seconds($0) }),
    ("m", { .seconds($0 * 60) }),
    ("h", { .seconds($0 * 3600) }),
  ]
  for unit in units where text.hasSuffix(unit.suffix) {
    let number = text.dropLast(unit.suffix.count)
    guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), let value = Int(number) else { return nil }
    return unit.make(value)
  }
  return nil
}

extension StringProtocol {
  func trimmingWhitespace() -> String {
    let characters = Array(self)
    guard let start = characters.firstIndex(where: { !$0.isWhitespace }),
      let end = characters.lastIndex(where: { !$0.isWhitespace })
    else { return "" }
    return String(characters[start...end])
  }
}

extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}
