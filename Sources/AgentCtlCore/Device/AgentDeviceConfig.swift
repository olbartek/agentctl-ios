import Foundation

extension AgentDevice {
  /// A push notification `device push <name> [tap]` delivers.
  public struct Push<Action: Sendable>: Sendable {
    public var name: String
    /// One line for the docs, e.g. `Order #1002 has shipped.`
    public var help: String
    /// Sent when the push arrives while the app is in front; `nil` when the app does nothing then.
    public var received: Action?
    /// Sent when the user taps the notification (`device push <name> tap`).
    public var opened: Action

    public init(_ name: String, help: String, received: Action? = nil, opened: Action) {
      self.name = name
      self.help = help
      self.received = received
      self.opened = opened
    }
  }
}

/// Which parts of the device an app lets scripts drive, and the root actions the device's events become
/// (CONTRACT.md §2.4). An app that configures nothing (``none``) has no `device` command at all.
public struct AgentDeviceConfig<Action: Sendable>: Sendable {
  /// The permission services `device permission` sets and the app's fakes request, e.g. `notifications`. App
  /// vocabulary, like mock methods. `biometry` is reserved.
  public var permissions: [String]
  /// The action a link opens, or `nil` for a link the app does not handle (`device open-url`).
  public var openURL: (@Sendable (URL) -> Action?)?
  /// The pushes `device push` delivers.
  public var pushes: [AgentDevice.Push<Action>]
  /// The action for the app entering a phase (`device background|foreground`), or `nil` for none.
  public var scenePhase: (@Sendable (AgentDevice.Phase) -> Action?)?
  /// Whether `device relaunch` exists.
  public var relaunch: Bool
  /// The error code every mocked call fails with while offline; non-`nil` enables `device network`.
  public var offlineErrorCode: String?
  /// Whether `device location` exists.
  public var location: Bool
  /// Whether `device biometry` exists.
  public var biometry: Bool

  public init(
    permissions: [String] = [],
    openURL: (@Sendable (URL) -> Action?)? = nil,
    pushes: [AgentDevice.Push<Action>] = [],
    scenePhase: (@Sendable (AgentDevice.Phase) -> Action?)? = nil,
    relaunch: Bool = false,
    offlineErrorCode: String? = nil,
    location: Bool = false,
    biometry: Bool = false
  ) {
    precondition(!permissions.contains("biometry"), "'biometry' is reserved: it names the biometric prompt")
    self.permissions = permissions
    self.openURL = openURL
    self.pushes = pushes
    self.scenePhase = scenePhase
    self.relaunch = relaunch
    self.offlineErrorCode = offlineErrorCode
    self.location = location
    self.biometry = biometry
  }

  /// No device capability: no `device` command.
  public static var none: Self { Self() }

  /// What scripts can address, without the actions: for the docs, `screens` and the runner's checks.
  public var surface: AgentDevice.Surface {
    var subcommands: [AgentDevice.Surface.Subcommand] = []
    if !permissions.isEmpty { subcommands += [.permission, .prompt] }
    if openURL != nil { subcommands.append(.openURL) }
    if !pushes.isEmpty { subcommands.append(.push) }
    if scenePhase != nil { subcommands += [.background, .foreground] }
    if relaunch { subcommands.append(.relaunch) }
    if offlineErrorCode != nil { subcommands.append(.network) }
    if location { subcommands.append(.location) }
    if biometry { subcommands.append(.biometry) }
    return AgentDevice.Surface(
      subcommands: subcommands,
      services: permissions,
      pushes: pushes.map { AgentDevice.Surface.Push(name: $0.name, help: $0.help) },
      offlineErrorCode: offlineErrorCode
    )
  }
}

extension AgentDevice {
  /// The `device` subcommands an app has, and the names they take: an ``AgentDeviceConfig`` without its actions.
  public struct Surface: Equatable, Sendable {
    /// In the contract's fixed order (CONTRACT.md §2.4).
    public enum Subcommand: String, CaseIterable, Equatable, Sendable {
      case permission
      case prompt
      case openURL = "open-url"
      case push
      case background
      case foreground
      case relaunch
      case network
      case location
      case biometry
    }

    public struct Push: Equatable, Sendable {
      public var name: String
      public var help: String

      public init(name: String, help: String) {
        self.name = name
        self.help = help
      }
    }

    /// The subcommands this app has, in the fixed order.
    public var subcommands: [Subcommand]
    public var services: [String]
    public var pushes: [Push]
    public var offlineErrorCode: String?

    public init(subcommands: [Subcommand], services: [String], pushes: [Push], offlineErrorCode: String?) {
      self.subcommands = subcommands
      self.services = services
      self.pushes = pushes
      self.offlineErrorCode = offlineErrorCode
    }

    /// No `device` command.
    public static let none = AgentDevice.Surface(subcommands: [], services: [], pushes: [], offlineErrorCode: nil)

    /// Whether `device` is a runtime command here.
    public var exists: Bool { !subcommands.isEmpty }

    /// Whether the app can show a system prompt (a permission's, or the biometric one): what `prompt=` reports.
    public var hasPrompts: Bool { subcommands.contains(.prompt) || subcommands.contains(.biometry) }

    /// The `CommandDoc`s of `device`, one per subcommand, as `screens` and the docs list them.
    public var commandDocs: [CommandDoc] {
      subcommands.map { sub in
        let (argument, help): (String, String) =
          switch sub {
          case .permission:
            (
              "permission <service> <not-determined|granted|denied|limited>",
              "Set a permission as if changed in Settings. Services: \(services.joined(separator: ", "))."
            )
          case .prompt:
            ("prompt <allow|deny|limited>", "Answer the system permission prompt the app is showing (prompt=<service>).")
          case .openURL:
            ("open-url <url>", "Open a link in the app, as a tapped deep link or universal link.")
          case .push:
            (
              "push <name> [tap]",
              "Deliver a push notification while the app is in front; with tap, open the app from it. Pushes: "
                + pushes.map { "\($0.name) (\($0.help))" }.joined(separator: ", ") + "."
            )
          case .background:
            ("background", "Send the app to the background; screen commands fail until device foreground.")
          case .foreground:
            ("foreground", "Bring the app back to the foreground.")
          case .relaunch:
            (
              "relaunch",
              "Quit and relaunch the app: its state starts over, while what its clients stored and the device's "
                + "settings stay."
            )
          case .network:
            (
              "network <online|offline>",
              "Turn the network off or on. Offline, every mocked call fails with \(offlineErrorCode ?? "")."
            )
          case .location:
            ("location <lat>,<lon>|none", "Set the device's location, e.g. 52.2297,21.0122, or none.")
          case .biometry:
            (
              "biometry <enrolled|unenrolled|match|fail>",
              "Enroll or remove Face ID / Touch ID, or answer the biometric prompt the app is showing (prompt=biometry)."
            )
          }
        return CommandDoc(name: "device", argument: argument, help: help, source: "runtime")
      }
    }
  }
}
