import Foundation
import Security

/// Defaults of the in-app bridge that both of its ends rely on: the app (`AgentLaunch`, in AgentCtlBridge) and
/// the CLI's `app` commands and `check --ui` (AgentCtlCLI). They live here, the one target both ends see, so the
/// two cannot drift apart. The bridge's wire protocol is CONTRACT.md §8.
public enum BridgeDefaults {
  /// The port the bridge listens on when the app is launched without `-agent-port`, and the port the CLI connects
  /// to when it is given no `--port`.
  public static let port: UInt16 = 8765

  /// This port's platform, as the bridge sends it in `X-Appctl-Platform` and the CLI records it in `bridge.json`:
  /// an app often has the same ID on iOS and on Android, so the ID alone cannot tell them apart (CONTRACT.md §8.6).
  public static let platform = "ios"
}

/// The bridge's token (CONTRACT.md §8.2, §8.4): a launch's secret, which the CLI makes and passes as `-agent-token`, and
/// every request then carries as `X-Appctl-Token`. Both ends use it — the CLI makes one, the app checks its form — so it
/// lives here beside ``BridgeDefaults``. A host names it as `AgentLaunchArguments.makeToken()` (AgentCtlBridge).
public enum BridgeToken {
  /// The launch argument that carries it.
  public static let argument = "-agent-token"
  /// The request header that carries it.
  public static let header = "X-Appctl-Token"

  /// A fresh token: 16 bytes from the system's secure random generator, as 32 lowercase hex characters.
  public static func make() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    // Without randomness there is no secret to hand out; a predictable token would be worse than none.
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// How a token appears in anything printed, logged or dumped: never as itself.
  public static let redacted = "<redacted>"

  /// Whether `token` is one: exactly 32 lowercase hex characters.
  public static func isWellFormed(_ token: String) -> Bool {
    let utf8 = token.utf8
    return utf8.count == 32 && utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// Whether `presented` is `expected`, in time that depends only on their lengths, not on where they differ.
  public static func matches(_ presented: String, _ expected: String) -> Bool {
    let presented = Array(presented.utf8)
    let expected = Array(expected.utf8)
    guard presented.count == expected.count else { return false }
    var difference: UInt8 = 0
    for index in expected.indices {
      difference |= presented[index] ^ expected[index]
    }
    return difference == 0
  }
}
