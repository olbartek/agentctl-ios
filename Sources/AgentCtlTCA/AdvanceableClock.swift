// Debug builds only (or a CLI built with -DAGENTCTL_RELEASE): see the note on this target in Package.swift.
#if DEBUG || AGENTCTL_RELEASE
  import Foundation
  import Synchronization

  /// The running app's clock: real time, which `advance` can move forward.
  ///
  /// ``now`` is the continuous clock plus an offset, and a sleep ends at its deadline in that time. Nothing moves the
  /// offset but ``advance(by:between:)``, which takes it forward deadline by deadline, so every timer due in the
  /// window fires, in deadline order, and the app gets to react to each before the next one — a countdown that
  /// sleeps a second at a time ticks once per second advanced, as it does on the headless `TestClock`.
  ///
  /// Only what sleeps on this clock moves. A timer on `Task.sleep`, a dispatch queue or a run loop keeps real time.
  public final class AdvanceableClock: Clock, Sendable {
    public typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()
    private let state = Mutex(State())

    private struct State {
      var offset: Duration = .zero
      var sleepers: [UUID: Sleeper] = [:]
    }

    public init() {}

    /// How far ``advance(by:between:)`` has moved this clock ahead of real time.
    public var offset: Duration { state.withLock { $0.offset } }

    public var now: Instant { base.now.advanced(by: offset) }
    public var minimumResolution: Duration { base.minimumResolution }

    /// The wall-clock date in this clock's time: `Date()` moved by ``offset``. For the app's `\.date`, and for any
    /// time source of the host's own that should move with `advance`.
    public func date() -> Date {
      Date().addingTimeInterval(Self.seconds(offset))
    }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
      while true {
        try Task.checkCancellation()
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else { return }
        // Wait out the rest in real time, unless `advance` wakes this sleep first; then look at the time again.
        let sleeper = Sleeper(deadline: deadline)
        let id = UUID()
        state.withLock { $0.sleepers[id] = sleeper }
        await withTaskGroup(of: Void.self) { group in
          group.addTask { [base] in try? await base.sleep(for: remaining, tolerance: tolerance) }
          group.addTask { await sleeper.wait() }
          await group.next()
          group.cancelAll()
          sleeper.wake()
        }
        state.withLock { _ = $0.sleepers.removeValue(forKey: id) }
      }
    }

    /// Moves the clock forward by `duration`. It stops at each sleep's deadline in the window, earliest first, wakes
    /// the sleeps that are due and awaits `between` — the app settling — so what they start is already waiting on
    /// the clock before it moves on.
    public func advance(by duration: Duration, between: @Sendable () async -> Void = {}) async {
      let target = offset + duration
      // A bound, in case a sleep keeps its deadline in the window without ever finishing.
      for _ in 0..<10_000 {
        let wall = base.now
        let (deadline, sleepers) = state.withLock { state -> (Instant?, [Sleeper]) in
          let limit = wall.advanced(by: target)
          let due = state.sleepers.values.map(\.deadline).filter { $0 <= limit }.min()
          guard let due else { return (nil, []) }
          // Never backwards: real time has passed since the offset was last set.
          state.offset = max(state.offset, wall.duration(to: due))
          return (due, Array(state.sleepers.values))
        }
        guard deadline != nil else { break }
        for sleeper in sleepers { sleeper.wake() }
        await between()
      }
      let sleepers = state.withLock { state -> [Sleeper] in
        state.offset = max(state.offset, target)
        return Array(state.sleepers.values)
      }
      for sleeper in sleepers { sleeper.wake() }
      await between()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// One waiting sleep. ``wake()`` ends ``wait()``, whether it comes before, during or after it, and only once.
    final class Sleeper: Sendable {
      let deadline: Instant
      private let state = Mutex<(woken: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))

      init(deadline: Instant) {
        self.deadline = deadline
      }

      func wait() async {
        await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            let woken = state.withLock { state -> Bool in
              if state.woken { return true }
              state.continuation = continuation
              return false
            }
            if woken { continuation.resume() }
          }
        } onCancel: {
          wake()
        }
      }

      func wake() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
          state.woken = true
          defer { state.continuation = nil }
          return state.continuation
        }
        continuation?.resume()
      }
    }
  }
#endif
