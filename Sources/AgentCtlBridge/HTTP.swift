#if DEBUG
  import AgentCtlCore
  import AgentCtlRuntime
  import Foundation

  /// A deliberately minimal HTTP/1.1 parser: request line, headers, `Content-Length` body. One request per
  /// connection. Enough for `appctl app …` and `curl`.
  enum HTTPParser {
    enum Result: Equatable {
      case incomplete
      case malformed
      case request(BridgeRequest)
    }

    /// A request's request line and headers, parsed once the blank line that ends them is in; the body may still be
    /// on its way.
    struct Head: Equatable {
      var method: String
      var target: String
      /// Every header as sent, in order: names keep their case.
      var headers: [(name: String, value: String)]
      var contentLength: Int
      /// Where the body starts in the data the head was parsed from.
      var bodyStart: Int

      /// The header called `name` (compared without regard to ASCII case, as HTTP names are), its values joined with
      /// `", "` when it was sent more than once; `nil` when it was not sent.
      func value(_ name: String) -> String? {
        let name = name.asciiLowercased
        let values = headers.filter { $0.name.asciiLowercased == name }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: ", ")
      }

      static func == (lhs: Head, rhs: Head) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.contentLength == rhs.contentLength
          && lhs.bodyStart == rhs.bodyStart && lhs.headers.map(\.name) == rhs.headers.map(\.name)
          && lhs.headers.map(\.value) == rhs.headers.map(\.value)
      }
    }

    enum HeadResult: Equatable {
      case incomplete
      case malformed
      case head(Head)
    }

    /// The most a request's header block may hold, the blank line that ends it included (CONTRACT.md §8.1).
    static let maxHeaderBytes = 64 * 1024
    /// The most a request's body may hold: a larger `Content-Length` is malformed, decided from the headers alone
    /// (CONTRACT.md §8.1).
    static let maxBodyBytes = 1024 * 1024

    static func parse(_ data: Data) -> Result {
      switch parseHead(data) {
      case .incomplete: .incomplete
      case .malformed: .malformed
      case let .head(head): request(head, in: data).map(Result.request) ?? .incomplete
      }
    }

    /// The request line and headers, without waiting for the body.
    static func parseHead(_ data: Data) -> HeadResult {
      guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
        return data.count > maxHeaderBytes ? .malformed : .incomplete
      }
      // However it arrived, in one read or several: the header block is malformed once it is over the limit.
      guard headerEnd.upperBound - data.startIndex <= maxHeaderBytes else { return .malformed }
      guard let text = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .malformed }
      let lines = text.components(separatedBy: "\r\n")
      let requestLine = lines[0].split(separator: " ")
      guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .malformed }

      var headers: [(name: String, value: String)] = []
      var contentLength: Int?
      for line in lines.dropFirst() {
        // A line folded onto the one before it (obs-fold) is malformed.
        guard let first = line.utf8.first, first != 0x20, first != 0x09 else { return .malformed }
        guard let colon = line.firstIndex(of: ":") else { return .malformed }
        let name = String(line[..<colon])
        // Whitespace between the name and its colon is malformed, as is a name that is not there.
        guard !name.isEmpty, !name.utf8.contains(where: { $0 == 0x20 || $0 == 0x09 }) else { return .malformed }
        let value = Self.trimmingOWS(line[line.index(after: colon)...])
        headers.append((name, value))
        switch name.asciiLowercased {
        case "transfer-encoding":
          // No chunked or any other coding: a body is exactly Content-Length bytes.
          return .malformed
        case "content-length":
          // One Content-Length, of plain ASCII digits, and no more than the cap.
          guard contentLength == nil, !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let length = Int(value), length <= maxBodyBytes
          else { return .malformed }
          contentLength = length
        default:
          break
        }
      }
      return .head(
        Head(
          method: String(requestLine[0]), target: String(requestLine[1]), headers: headers,
          contentLength: contentLength ?? 0, bodyStart: headerEnd.upperBound
        )
      )
    }

    /// A header value without the optional whitespace (spaces and tabs only) around it.
    static func trimmingOWS(_ value: Substring) -> String {
      let isOWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
      guard let start = value.firstIndex(where: { !isOWS($0) }), let end = value.lastIndex(where: { !isOWS($0) }) else {
        return ""
      }
      return String(value[start...end])
    }

    /// The whole request, once `data` holds all of its body; `nil` until then.
    static func request(_ head: Head, in data: Data) -> BridgeRequest? {
      guard data.endIndex - head.bodyStart >= head.contentLength else { return nil }
      let body = String(decoding: data[head.bodyStart..<(head.bodyStart + head.contentLength)], as: UTF8.self)
      let components = URLComponents(string: head.target)
      var query: [String: String] = [:]
      for item in components?.queryItems ?? [] {
        query[item.name] = item.value ?? ""
      }
      return BridgeRequest(method: head.method, path: components?.path ?? head.target, query: query, body: body)
    }

    /// The response on the wire. `app` is the app's bundle ID, sent as `X-Appctl-App` with `X-Appctl-Platform: ios`, so
    /// a CLI can tell its own app from another one on the same port, the same app on Android included (CONTRACT.md §8.4).
    static func serialize(
      _ response: BridgeResponse, app: String? = nil, platform: String? = BridgeDefaults.platform
    ) -> Data {
      let body = Data(response.body.utf8)
      let reason =
        switch response.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
      let head = [
        "HTTP/1.1 \(response.status) \(reason)",
        "Content-Type: \(response.contentType)",
        "Content-Length: \(body.count)",
        "X-Appctl-Exit: \(response.exitCode)",
        app.map { "X-Appctl-App: \($0)" },
        app.flatMap { _ in platform }.map { "X-Appctl-Platform: \($0)" },
        "Connection: close",
        "",
        "",
      ].compactMap { $0 }.joined(separator: "\r\n")
      return Data(head.utf8) + body
    }
  }

  /// Who may use the bridge (CONTRACT.md §8.4), checked once a request's headers are in, before its body is read
  /// and before it is routed: first where it is addressed and whether a web page sent it, then its token.
  enum BridgeAccess {
    /// The Host names the bridge answers to. The port is not compared: through `adb forward`, the host-side port
    /// differs from the app's.
    static let hostNames = ["127.0.0.1", "localhost"]

    static let forbidden = BridgeResponse(status: 403, body: "forbidden\n", exitCode: 3)
    static let unauthorized = BridgeResponse(status: 401, body: "unauthorized\n", exitCode: 3)

    /// The answer that refuses the request, or `nil` when it may go on to routing. A header sent more than once counts
    /// as its values joined with `", "`, so a second Host or `X-Appctl-Token` never matches.
    static func refusal(_ head: HTTPParser.Head, token: String) -> BridgeResponse? {
      guard let host = head.value("Host"), isLoopback(host), head.value("Origin") == nil else { return forbidden }
      guard let presented = head.value(BridgeToken.header), BridgeToken.isWellFormed(presented),
        BridgeToken.matches(presented, token)
      else { return unauthorized }
      return nil
    }

    /// Whether a Host value is one of ``hostNames`` (ASCII case aside) with, after its last `:`, a port of ASCII digits
    /// or nothing. The port's value is not compared.
    static func isLoopback(_ host: String) -> Bool {
      var name = Substring(host)
      if let colon = host.lastIndex(of: ":") {
        guard host[host.index(after: colon)...].utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return false }
        name = host[..<colon]
      }
      return hostNames.contains(String(name).asciiLowercased)
    }
  }

  extension String {
    /// Lowercased in ASCII only: HTTP compares names without regard to ASCII case, and nothing else may fold into them.
    fileprivate var asciiLowercased: String {
      String(decoding: utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
  }
#endif
