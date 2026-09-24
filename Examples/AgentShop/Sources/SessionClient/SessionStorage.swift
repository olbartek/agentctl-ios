import ComposableArchitecture
import Foundation
import Models

/// A saved session, and whether the user chose "Keep me signed in".
public struct StoredSession: Codable, Equatable, Sendable {
  public var session: Session
  /// When false, the session only lasts until the app is relaunched.
  public var remember: Bool

  public init(session: Session, remember: Bool) {
    self.session = session
    self.remember = remember
  }
}

/// Where ``SessionClient`` keeps the session. Other mocks read it directly (without logging a call) to know
/// who is signed in, the way a server reads a token.
public struct SessionStorage: Sendable {
  public var load: @Sendable () -> StoredSession?
  public var store: @Sendable (StoredSession?) -> Void

  public init(load: @escaping @Sendable () -> StoredSession?, store: @escaping @Sendable (StoredSession?) -> Void) {
    self.load = load
    self.store = store
  }

  /// The signed-in user's session, remembered or not.
  public var currentSession: Session? { load()?.session }

  public static func inMemory(_ initial: StoredSession? = nil) -> Self {
    let stored = LockIsolated(initial)
    return Self(load: { stored.value }, store: { stored.setValue($0) })
  }

  /// JSON in `UserDefaults`, under `key`. `suiteName: nil` uses the standard suite.
  public static func userDefaults(suiteName: String? = nil, key: String = "agentshop.session") -> Self {
    @Sendable func defaults() -> UserDefaults {
      suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
    return Self(
      load: {
        guard let data = defaults().data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
      },
      store: { stored in
        if let stored, let data = try? JSONEncoder().encode(stored) {
          defaults().set(data, forKey: key)
        } else {
          defaults().removeObject(forKey: key)
        }
      }
    )
  }
}

extension SessionStorage: DependencyKey {
  public static let liveValue = SessionStorage.userDefaults()
  public static var testValue: SessionStorage { .inMemory() }
  public static var previewValue: SessionStorage { .inMemory() }
}

extension DependencyValues {
  public var sessionStorage: SessionStorage {
    get { self[SessionStorage.self] }
    set { self[SessionStorage.self] = newValue }
  }
}
