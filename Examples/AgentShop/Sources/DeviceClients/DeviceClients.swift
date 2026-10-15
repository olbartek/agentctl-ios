import AgentCtlCore
import ComposableArchitecture
import Models
import Synchronization

/// Asking for permission to send notifications. In this all-mock app it is AgentCtl's simulated device
/// (`\.agentDevice`), so a script answers the system prompt with `device prompt allow|deny`; a real app would call
/// `UNUserNotificationCenter.requestAuthorization` in its live value instead.
@DependencyClient
public struct NotificationsClient: Sendable {
  public var requestAuthorization: @Sendable () async -> PermissionStatus = { .notDetermined }
}

extension NotificationsClient: DependencyKey {
  public static let liveValue = NotificationsClient(
    requestAuthorization: {
      @Dependency(\.agentDevice) var device
      return await device.requestPermission("notifications")
    }
  )
  public static let testValue = NotificationsClient()
}

/// The device's location and the permission to read it, through the simulated device (`device location`,
/// `device permission location …`).
@DependencyClient
public struct LocationClient: Sendable {
  public var requestAuthorization: @Sendable () async -> PermissionStatus = { .notDetermined }
  public var current: @Sendable () async -> DeviceLocation? = { nil }
}

extension LocationClient: DependencyKey {
  public static let liveValue = LocationClient(
    requestAuthorization: {
      @Dependency(\.agentDevice) var device
      return await device.requestPermission("location")
    },
    current: {
      @Dependency(\.agentDevice) var device
      return device.location
    }
  )
  public static let testValue = LocationClient()
}

/// Face ID, through the simulated device (`device biometry …`).
@DependencyClient
public struct BiometricsClient: Sendable {
  public var authenticate: @Sendable () async -> BiometryResult = { .unavailable }
}

extension BiometricsClient: DependencyKey {
  public static let liveValue = BiometricsClient(
    authenticate: {
      @Dependency(\.agentDevice) var device
      return await device.authenticateBiometry()
    }
  )
  public static let testValue = BiometricsClient()
}

/// The account that signs in with Face ID, as a real app would keep it in the keychain. It outlives a log-out and a
/// relaunch (`device relaunch`); a headless run starts with an empty one.
public final class FaceIDVault: Sendable {
  private let stored = Mutex<Session?>(nil)

  public init() {}

  public var session: Session? { stored.withLock { $0 } }

  public func enable(_ session: Session) { stored.withLock { $0 = session } }

  public func disable() { stored.withLock { $0 = nil } }
}

extension FaceIDVault: DependencyKey {
  public static let liveValue = FaceIDVault()
  public static var testValue: FaceIDVault { FaceIDVault() }
}

extension DependencyValues {
  public var notificationsClient: NotificationsClient {
    get { self[NotificationsClient.self] }
    set { self[NotificationsClient.self] = newValue }
  }

  public var locationClient: LocationClient {
    get { self[LocationClient.self] }
    set { self[LocationClient.self] = newValue }
  }

  public var biometricsClient: BiometricsClient {
    get { self[BiometricsClient.self] }
    set { self[BiometricsClient.self] = newValue }
  }

  public var faceIDVault: FaceIDVault {
    get { self[FaceIDVault.self] }
    set { self[FaceIDVault.self] = newValue }
  }
}
