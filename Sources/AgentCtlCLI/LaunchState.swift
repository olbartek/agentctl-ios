#if os(macOS) && (DEBUG || AGENTCTL_RELEASE)
  import AgentCtlCore
  import Foundation

  /// `<outputPath>/bridge.json`: where the last `app launch` (or `app test`, or `check --ui`) left the app, so the
  /// other `app` commands find its bridge without a `--port`.
  ///
  /// The file is shared with agentctl-android byte for byte in form: sorted keys, pretty-printed, one trailing
  /// newline.
  struct LaunchState: Codable, Equatable {
    /// `ios` here; `android` in the Kotlin port.
    var platform: String
    /// The simulator's UDID.
    var device: String
    var port: Int
    /// The app's bundle ID.
    var appId: String
    /// When the bridge first answered, ISO 8601 in UTC to the second.
    var launchedAt: String

    static let fileName = "bridge.json"

    /// Where the file lives, relative to the repo root, as messages spell it.
    static var relativePath: String { "\(AgentCtl.runtime.outputPath)/\(fileName)" }

    static func file(in root: URL) -> URL {
      Layout(root: root).output.appending(path: fileName)
    }

    init(platform: String = "ios", device: String, port: Int, appId: String, launchedAt: Date) {
      self.platform = platform
      self.device = device
      self.port = port
      self.appId = appId
      self.launchedAt = Self.timestamp(launchedAt)
    }

    static func timestamp(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      formatter.timeZone = TimeZone(identifier: "UTC")
      return formatter.string(from: date)
    }

    func encoded() throws -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    func write(in root: URL) throws {
      let file = Self.file(in: root)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoded().write(to: file, atomically: true, encoding: .utf8)
    }

    /// The last launch's state, or `nil` when there is no file.
    static func read(in root: URL) throws -> LaunchState? {
      let file = file(in: root)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      do {
        return try JSONDecoder().decode(LaunchState.self, from: Data(contentsOf: file))
      } catch {
        throw AppCtlError(Message.unreadableLaunchState(error: error))
      }
    }
  }

  /// Which port the `app` commands use.
  ///
  /// `--port` wins, then `APPCTL_PORT`. Beyond those, a launch takes 8765 if it is free and otherwise the next free
  /// port above it, and the commands that talk to a running app read the port the last launch recorded, falling
  /// back to 8765.
  enum BridgePort {
    static let environmentVariable = "APPCTL_PORT"
    /// The ports a launch tries, in order.
    static let scanned = Int(BridgeDefaults.port)...(Int(BridgeDefaults.port) + 99)

    /// Where a connecting command's port came from, so a failure can say why it tried that one.
    enum Source: Equatable {
      case flag
      case environment
      case launchState(LaunchState)
      case defaultPort
    }

    /// The port named by `--port` or, failing that, `APPCTL_PORT`; `nil` when neither is given.
    static func requested(flag: Int?, environment: [String: String]) throws -> Int? {
      if let flag { return flag }
      guard let value = environment[environmentVariable], !value.isEmpty else { return nil }
      guard let port = Int(value), (1...65535).contains(port) else {
        throw UsageError(Message.badPortVariable(value))
      }
      return port
    }

    /// The port a command that talks to a running app connects to.
    static func connecting(
      flag: Int?, environment: [String: String], launchState: () throws -> LaunchState?
    ) throws -> (port: Int, source: Source) {
      if let flag { return (flag, .flag) }
      if let port = try requested(flag: nil, environment: environment) { return (port, .environment) }
      if let state = try launchState() { return (state.port, .launchState(state)) }
      return (Int(BridgeDefaults.port), .defaultPort)
    }

    /// The port a launch binds the bridge to: the requested one as it is, else the first free one of ``scanned``.
    static func launching(requested: Int?, isFree: (Int) -> Bool = isFree) throws -> Int {
      if let requested { return requested }
      guard let port = scanned.first(where: isFree) else { throw AppCtlError(Message.noFreePort) }
      return port
    }

    /// Whether nothing listens on `127.0.0.1:port`, so the app's bridge can take it.
    ///
    /// The bridge binds with address reuse, so a plain `bind` succeeding is not enough: another process (`adb`
    /// forwarding the same port, a second app) may already be listening there. This connects first, then binds
    /// the way the bridge does.
    static func isFree(_ port: Int) -> Bool {
      guard let port = UInt16(exactly: port) else { return false }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")

      func withSocket(_ body: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        return withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
      if withSocket({ connect($0, $1, $2) }) == 0 { return false }
      return withSocket({ bind($0, $1, $2) }) == 0
    }
  }

  /// A usage error found after parsing, such as a bad `APPCTL_PORT`: exit 2 (CONTRACT.md §5).
  struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }
#endif
