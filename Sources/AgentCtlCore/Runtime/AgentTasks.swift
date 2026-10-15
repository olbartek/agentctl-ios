import Dependencies
import Synchronization

/// Where an app that starts its own `Task`s — an MVVM-C app's view models — starts them, so the agent runtime can
/// see its work start and finish, and so the work runs in the dependencies of the object that started it.
///
/// ```swift
/// @ObservationIgnored @Dependency(\.agentTasks) private var tasks
///
/// func refresh() {
///   loadTask?.cancel()
///   loadTask = tasks.run(for: self) { [weak self, client] in
///     let items = try? await client.fetch()
///     guard !Task.isCancelled, let self else { return }
///     self.items = items ?? []
///   }
/// }
/// ```
///
/// The owner's dependencies, not the caller's context: in the running app a view model's methods are called from
/// SwiftUI, outside any `withDependencies`, and a task started there would see the app-wide values — a `mockCall`
/// would log to the wrong call log and wait the default latency on the real clock.
///
/// In a Release build it is a plain `Task`, plus one atomic count. A TCA app does not need it: its effects are counted
/// by the store.
public final class AgentTasks: Sendable {
  private let count = Mutex(0)

  public init() {}

  /// Tasks started and not yet finished, including ones suspended on the clock (a countdown).
  public var inFlight: Int { count.withLock { $0 } }

  /// Starts `operation` on the main actor in `owner`'s dependencies (the values its `@Dependency`s captured when it
  /// was created), counted until it returns. Keep the returned task to cancel it.
  @discardableResult
  public func run<Owner: AnyObject>(
    for owner: Owner,
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    count.withLock { $0 += 1 }
    return withDependencies(from: owner) {
      withEscapedDependencies { dependencies in
        Task { @MainActor in
          defer { self.count.withLock { $0 -= 1 } }
          await dependencies.yield { await operation() }
        }
      }
    }
  }
}

extension AgentTasks: DependencyKey {
  public static let liveValue = AgentTasks()
  public static var testValue: AgentTasks { AgentTasks() }
}

extension DependencyValues {
  /// Where view models start their `Task`s. Each agent host binds its own, so settling counts only its app's work.
  public var agentTasks: AgentTasks {
    get { self[AgentTasks.self] }
    set { self[AgentTasks.self] = newValue }
  }
}
