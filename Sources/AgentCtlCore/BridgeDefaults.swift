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
