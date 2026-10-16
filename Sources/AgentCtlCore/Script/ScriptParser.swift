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

/// Parses the script language shared by the CLI's `run`, scenarios, `-appctl-seed` and the agent bridge.
///
/// - Commands are separated by `;` or newlines. A newline is `\n` or `\r\n`; a lone `\r` is whitespace.
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
      if character.isScriptNewline {
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
  /// Only one quoted span counts: the quote that closes the opening one must be the last character, so `"a"b"c"`
  /// and `"a" "b"` stay as written.
  public static func unquoted(_ text: String) -> String {
    guard text.first == "\"" else { return text }
    var content = ""
    var escaping = false
    for (offset, character) in text.dropFirst().enumerated() {
      if escaping {
        content.append(character)
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else if character == "\"" {
        // The closing quote: the argument is one quoted span only if nothing follows it.
        return offset == text.count - 2 ? content : text
      } else {
        content.append(character)
      }
    }
    return text
  }

  /// Splits on unquoted whitespace, then removes quotes and resolves escapes in each token.
  /// `name="Alice Smith" email=a` → `["name=Alice Smith", "email=a"]`.
  public static func tokens(_ text: String) -> [String] {
    splitTokens(text).map(\.text)
  }

  /// Splits `text` into `key=value` pairs at each token's first *unquoted* `=`, the key and value unquoted
  /// (CONTRACT.md §2.1). `nil` for a token whose `=` is missing, only inside quotes, or first: `"title=a b"` is
  /// not a pair, `"a=b"=c` is the key `a=b`.
  static func pairs(_ text: String) -> [(token: String, pair: (key: String, value: String)?)] {
    splitTokens(text).map { token in
      guard let equals = token.equals, equals > 0 else { return (token.text, nil) }
      let index = token.text.index(token.text.startIndex, offsetBy: equals)
      return (token.text, (String(token.text[..<index]), String(token.text[token.text.index(after: index)...])))
    }
  }

  /// Each token, unquoted, with the offset in it of its first `=` that was outside quotes.
  private static func splitTokens(_ text: String) -> [(text: String, equals: Int?)] {
    var tokens: [(text: String, equals: Int?)] = []
    var current = ""
    var equals: Int?
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
        if hasToken { tokens.append((current, equals)) }
        current = ""
        equals = nil
        hasToken = false
      } else {
        if character == "=", equals == nil { equals = current.count }
        current.append(character)
        hasToken = true
      }
    }
    if hasToken { tokens.append((current, equals)) }
    return tokens
  }
}

extension ScriptParser {
  /// Parses the argument of `advance`: an unsigned integer immediately followed by one unit — `ms`, `s`, `m` or
  /// `h` (`500ms`, `30s`, `5m`, `1h`; CONTRACT.md §2.2).
  ///
  /// Returns `nil` for anything else, including a number too large to represent, whether as an `Int` or once
  /// converted to seconds: `advance` reports every `nil` as a usage error (exit 2), never a crash.
  public static func parseDuration(_ text: String) -> Duration? {
    // The multiplier to seconds; `nil` for milliseconds, which `Duration` takes as they are. `ms` is tried
    // before `s` and `m`, which are its suffix and its first letter.
    let units: [(suffix: String, seconds: Int?)] = [("ms", nil), ("s", 1), ("m", 60), ("h", 3600)]
    for unit in units where text.hasSuffix(unit.suffix) {
      let number = text.dropLast(unit.suffix.count)
      guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), let value = Int(number) else { return nil }
      guard let multiplier = unit.seconds else { return .milliseconds(value) }
      let (seconds, overflow) = value.multipliedReportingOverflow(by: multiplier)
      return overflow ? nil : .seconds(seconds)
    }
    return nil
  }
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

  /// A line break in a script (CONTRACT.md §1.1): `\n`, or `\r\n`, which Swift reads as one `Character`. A lone
  /// `\r` is not one.
  var isScriptNewline: Bool { self == "\n" || self == "\r\n" }
}
