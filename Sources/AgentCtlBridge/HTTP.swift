#if DEBUG
  import AgentCtlTCA
  import Foundation

  /// A deliberately minimal HTTP/1.1 parser: request line, headers, `Content-Length` body. One request per
  /// connection. Enough for `appctl app …` and `curl`.
  enum HTTPParser {
    enum Result: Equatable {
      case incomplete
      case malformed
      case request(BridgeRequest)
    }

    static func parse(_ data: Data) -> Result {
      guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
        return data.count > 64 * 1024 ? .malformed : .incomplete
      }
      guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .malformed }
      let lines = head.components(separatedBy: "\r\n")
      let requestLine = lines[0].split(separator: " ")
      guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .malformed }

      var contentLength = 0
      for line in lines.dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return .malformed }
        if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
          guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), length >= 0 else { return .malformed }
          contentLength = length
        }
      }
      let bodyStart = headerEnd.upperBound
      guard data.count - bodyStart >= contentLength else { return .incomplete }
      let body = String(decoding: data[bodyStart..<(bodyStart + contentLength)], as: UTF8.self)

      let target = String(requestLine[1])
      let components = URLComponents(string: target)
      var query: [String: String] = [:]
      for item in components?.queryItems ?? [] {
        query[item.name] = item.value ?? ""
      }
      return .request(
        BridgeRequest(method: String(requestLine[0]), path: components?.path ?? target, query: query, body: body)
      )
    }

    static func serialize(_ response: BridgeResponse) -> Data {
      let body = Data(response.body.utf8)
      let reason =
        switch response.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
      let head = [
        "HTTP/1.1 \(response.status) \(reason)",
        "Content-Type: \(response.contentType)",
        "Content-Length: \(body.count)",
        "X-Appctl-Exit: \(response.exitCode)",
        "Connection: close",
        "",
        "",
      ].joined(separator: "\r\n")
      return Data(head.utf8) + body
    }
  }
#endif
