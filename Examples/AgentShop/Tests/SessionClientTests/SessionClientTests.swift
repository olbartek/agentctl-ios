import AgentCtlCore
import ComposableArchitecture
import Foundation
import Models
import SessionClient
import Testing

struct SessionClientTests {
  let alice = Session(user: User(id: "u1", name: "Alice", email: "alice@example.com"), token: "mock-token-u1")

  @Test func saveCurrentClearAreLogged() async {
    let log = MockCallLog()
    await withDependencies {
      $0.mockCallLog = log
      $0.sessionStorage = .inMemory()
    } operation: {
      let client = SessionClient.liveValue
      #expect(await client.current() == nil)
      await client.save(alice, true)
      #expect(await client.current() == alice)
      await client.clear()
      #expect(await client.current() == nil)
    }
    #expect(log.entries == ["session.current", "session.save", "session.current", "session.clear", "session.current"])
  }

  /// "Keep me signed in" off: the session works until relaunch, when `current()` drops it.
  @Test func sessionsNotRememberedAreNotRestored() async {
    let storage = SessionStorage.inMemory()
    await withDependencies {
      $0.mockCallLog = MockCallLog()
      $0.sessionStorage = storage
    } operation: {
      let client = SessionClient.liveValue
      await client.save(alice, false)
      #expect(storage.currentSession == alice)
      #expect(await client.current() == nil)
      #expect(storage.currentSession == nil)
    }
  }

  @Test func userDefaultsStorageRoundTrips() throws {
    let suite = "agentshop.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let storage = SessionStorage.userDefaults(suiteName: suite)
    let stored = StoredSession(session: alice, remember: true)
    #expect(storage.load() == nil)
    storage.store(stored)
    #expect(storage.load() == stored)
    // A second instance reads the same suite, as a relaunched app would.
    #expect(SessionStorage.userDefaults(suiteName: suite).load() == stored)
    storage.store(nil)
    #expect(storage.load() == nil)
  }

  @Test func inMemoryStorage() {
    let storage = SessionStorage.inMemory(StoredSession(session: alice, remember: false))
    #expect(storage.currentSession == alice)
    storage.store(nil)
    #expect(storage.load() == nil)
  }
}
