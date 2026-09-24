import AgentCtlCore
import ComposableArchitecture
import Models

/// Keeps the signed-in session. In the app it survives relaunches (a mock keychain backed by `UserDefaults`);
/// in `appctl` and tests it lives in memory.
@DependencyClient
public struct SessionClient: Sendable {
  /// The session to restore at launch: only one saved with "Keep me signed in". A session that wasn't
  /// remembered is cleared instead, as a relaunch would have lost it.
  public var current: @Sendable () async -> Session? = { nil }
  /// Saves the signed-in session. `remember: false` means it won't survive a relaunch.
  public var save: @Sendable (_ session: Session, _ remember: Bool) async -> Void
  public var clear: @Sendable () async -> Void
}

extension SessionClient: DependencyKey {
  public static let liveValue = SessionClient(
    current: {
      loggedCall("session.current") {
        @Dependency(\.sessionStorage) var storage
        guard let stored = storage.load() else { return nil }
        guard stored.remember else {
          storage.store(nil)
          return nil
        }
        return stored.session
      }
    },
    save: { session, remember in
      loggedCall("session.save") {
        @Dependency(\.sessionStorage) var storage
        storage.store(StoredSession(session: session, remember: remember))
      }
    },
    clear: {
      loggedCall("session.clear") {
        @Dependency(\.sessionStorage) var storage
        storage.store(nil)
      }
    }
  )

  public static let testValue = SessionClient()
  public static let previewValue = liveValue
}

extension DependencyValues {
  public var sessionClient: SessionClient {
    get { self[SessionClient.self] }
    set { self[SessionClient.self] = newValue }
  }
}

/// Session calls are logged like every mock call, but have no latency and cannot fail.
private func loggedCall<T>(_ name: String, _ body: () -> T) -> T {
  @Dependency(\.mockCallLog) var log
  log.begin(name)
  defer { log.end(name) }
  return body()
}
