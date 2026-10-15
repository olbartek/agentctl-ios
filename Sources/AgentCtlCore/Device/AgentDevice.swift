import Dependencies
import Synchronization

/// A permission's status, as the app's permission fakes report it (CONTRACT.md §2.4).
public enum PermissionStatus: String, CaseIterable, Equatable, Sendable {
  case notDetermined = "not-determined"
  case granted
  case denied
  case limited
}

/// What a biometric authentication (Face ID, Touch ID, a fingerprint) came to.
public enum BiometryResult: Equatable, Sendable {
  case success
  case failure
  /// No biometry is enrolled, so no prompt was shown.
  case unavailable
}

/// Whether the app is in front.
public enum DevicePhase: String, Equatable, Sendable {
  case foreground
  case background
}

/// A position on Earth, in degrees.
public struct DeviceLocation: Equatable, Hashable, Sendable {
  public var latitude: Double
  public var longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  /// `<lat>,<lon>`: each an optional `-`, digits, and an optional `.` and digits; latitude within [-90, 90],
  /// longitude within [-180, 180]; no spaces (CONTRACT.md §2.4). `nil` for anything else.
  public static func parse(_ text: String) -> DeviceLocation? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let latitude = decimal(parts[0]), let longitude = decimal(parts[1]),
      (-90...90).contains(latitude), (-180...180).contains(longitude)
    else { return nil }
    return DeviceLocation(latitude: latitude, longitude: longitude)
  }

  /// `device location`'s argument: a location, or `none` (`.some(nil)`); `nil` when it is neither.
  public static func parseArgument(_ text: String) -> DeviceLocation?? {
    text == "none" ? .some(nil) : parse(text).map { .some($0) }
  }

  private static func decimal(_ text: Substring) -> Double? {
    var rest = text
    if rest.first == "-" { rest = rest.dropFirst() }
    let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
    else { return nil }
    return Double(text)
  }
}

/// The simulated device an app's environment fakes read: permissions and their system prompts, connectivity,
/// location, biometry and whether the app is in front. The `device` runtime command changes it (CONTRACT.md §2.4).
///
/// One device per host, as `\.agentDevice`. The app routes its own clients' fakes through it, as it routes backend
/// calls through ``mockCall(_:error:_:)``:
///
/// ```swift
/// extension NotificationsClient {
///   static let agentValue = NotificationsClient(
///     status: { @Dependency(\.agentDevice) var device; return device.permission("notifications") },
///     request: { @Dependency(\.agentDevice) var device; return await device.requestPermission("notifications") }
///   )
/// }
/// ```
///
/// Outside a host — a preview, a Release build of a mock-backed app — the device is *undriven*: online, no location,
/// biometry enrolled, and every request answered at once, as if the user allowed it, so nothing ever waits for a
/// prompt no one can answer. A host's device is *driven*: a request shows a prompt that only `device prompt` (or
/// `device biometry`) answers.
public final class AgentDevice: Sendable {
  /// A system prompt the app is waiting on.
  enum Prompt: Equatable, Sendable {
    case permission(String)
    case biometry

    var name: String {
      switch self {
      case let .permission(service): service
      case .biometry: "biometry"
      }
    }
  }

  enum Answer: Sendable {
    case permission(PermissionStatus)
    case biometry(BiometryResult)
  }

  private struct Waiting {
    var id: UInt64
    var prompt: Prompt
    var continuation: CheckedContinuation<Answer, Never>
  }

  private struct State {
    var statuses: [String: PermissionStatus] = [:]
    var waiting: [Waiting] = []
    /// Requests cancelled before their prompt was queued.
    var withdrawn: Set<UInt64> = []
    var nextID: UInt64 = 0
    var isOnline = true
    var location: DeviceLocation?
    var isBiometryEnrolled = true
    var phase = DevicePhase.foreground
    var onlineObservers: [UInt64: AsyncStream<Bool>.Continuation] = [:]
    var locationObservers: [UInt64: AsyncStream<DeviceLocation?>.Continuation] = [:]
  }

  /// Whether requests wait for an answer (`true` in a host) or are granted at once.
  public let isDriven: Bool
  /// The error code every mocked call fails with while offline (``AgentDeviceConfig/offlineErrorCode``).
  public let offlineErrorCode: String?
  private let state = Mutex(State())

  /// An undriven device: every request is granted at once.
  public convenience init() {
    self.init(driven: false)
  }

  /// - Parameters:
  ///   - driven: `true` for a host's device, whose requests show prompts the `device` command answers.
  ///   - offlineErrorCode: the code mocked calls fail with while offline.
  public init(driven: Bool, offlineErrorCode: String? = nil) {
    isDriven = driven
    self.offlineErrorCode = offlineErrorCode
  }

  // MARK: - What the app's fakes read

  /// The permission's current status. A service nothing has set is `not-determined`.
  public func permission(_ service: String) -> PermissionStatus {
    state.withLock { $0.statuses[service] ?? .notDetermined }
  }

  /// Requests a permission. When its status is `not-determined`, a system prompt opens and this waits for the
  /// answer (`device prompt allow|deny|limited`); otherwise it returns the current status at once. An undriven
  /// device grants it at once. Cancelling the waiting task withdraws the prompt and returns the status unchanged.
  public func requestPermission(_ service: String) async -> PermissionStatus {
    let answer = await waitForAnswer(.permission(service)) { state in
      let status = state.statuses[service] ?? .notDetermined
      guard status == .notDetermined else { return .permission(status) }
      guard isDriven else {
        state.statuses[service] = .granted
        return .permission(.granted)
      }
      return nil
    }
    guard case let .permission(status) = answer else { return permission(service) }
    return status
  }

  /// Whether the device has a network connection. Offline, every ``mockCall(_:error:_:)`` fails.
  public var isOnline: Bool {
    state.withLock { $0.isOnline }
  }

  /// The connection: the current value first, then each change.
  public func onlineUpdates() -> AsyncStream<Bool> {
    AsyncStream { continuation in
      let id = state.withLock { state in
        let id = state.nextID
        state.nextID += 1
        state.onlineObservers[id] = continuation
        continuation.yield(state.isOnline)
        return id
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.state.withLock { $0.onlineObservers.removeValue(forKey: id) }
      }
    }
  }

  /// The device's location, or `nil` when it has none.
  public var location: DeviceLocation? {
    state.withLock { $0.location }
  }

  /// The location: the current value first, then each change.
  public func locationUpdates() -> AsyncStream<DeviceLocation?> {
    AsyncStream { continuation in
      let id = state.withLock { state in
        let id = state.nextID
        state.nextID += 1
        state.locationObservers[id] = continuation
        continuation.yield(state.location)
        return id
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.state.withLock { $0.locationObservers.removeValue(forKey: id) }
      }
    }
  }

  /// Whether Face ID / Touch ID is enrolled.
  public var isBiometryEnrolled: Bool {
    state.withLock { $0.isBiometryEnrolled }
  }

  /// Authenticates with biometry: ``BiometryResult/unavailable`` at once when none is enrolled; otherwise a
  /// biometric prompt opens and this waits for `device biometry match|fail`. An undriven device succeeds at once.
  public func authenticateBiometry() async -> BiometryResult {
    let answer = await waitForAnswer(.biometry) { state in
      guard state.isBiometryEnrolled else { return .biometry(.unavailable) }
      return isDriven ? nil : .biometry(.success)
    }
    guard case let .biometry(result) = answer else { return .failure }
    return result
  }

  /// Whether the app is in front.
  public var phase: DevicePhase {
    state.withLock { $0.phase }
  }

  // MARK: - What the runtime changes

  /// The oldest prompt the app is waiting on: what a step prints as `prompt=`.
  package var pendingPrompt: String? {
    state.withLock { $0.waiting.first?.prompt.name }
  }

  /// Whether a prompt for `service` is waiting.
  package func isPrompting(for service: String) -> Bool {
    state.withLock { $0.waiting.contains { $0.prompt == .permission(service) } }
  }

  package func setPermission(_ service: String, _ status: PermissionStatus) {
    state.withLock { $0.statuses[service] = status }
  }

  package enum AnswerError: Error, Equatable {
    case noPrompt
    /// The oldest prompt is of the other kind.
    case otherPrompt(String)
  }

  /// Answers the oldest prompt, which must be a permission's: its status becomes `status`.
  package func answerPermission(_ status: PermissionStatus) throws(AnswerError) {
    let waiting: Waiting = try state.withLock { (state: inout State) throws(AnswerError) -> Waiting in
      guard let first = state.waiting.first else { throw .noPrompt }
      guard case let .permission(service) = first.prompt else { throw .otherPrompt(first.prompt.name) }
      state.statuses[service] = status
      return state.waiting.removeFirst()
    }
    waiting.continuation.resume(returning: .permission(status))
  }

  /// Answers the oldest prompt, which must be the biometric one.
  package func answerBiometry(_ result: BiometryResult) throws(AnswerError) {
    let waiting: Waiting = try state.withLock { (state: inout State) throws(AnswerError) -> Waiting in
      guard let first = state.waiting.first else { throw .noPrompt }
      guard first.prompt == .biometry else { throw .otherPrompt(first.prompt.name) }
      return state.waiting.removeFirst()
    }
    waiting.continuation.resume(returning: .biometry(result))
  }

  package func setOnline(_ online: Bool) {
    let observers = state.withLock { state in
      state.isOnline = online
      return Array(state.onlineObservers.values)
    }
    for observer in observers { observer.yield(online) }
  }

  package func setLocation(_ location: DeviceLocation?) {
    let observers = state.withLock { state in
      state.location = location
      return Array(state.locationObservers.values)
    }
    for observer in observers { observer.yield(location) }
  }

  package func setBiometryEnrolled(_ enrolled: Bool) {
    state.withLock { $0.isBiometryEnrolled = enrolled }
  }

  package func setPhase(_ phase: DevicePhase) {
    state.withLock { $0.phase = phase }
  }

  /// Withdraws every prompt, as quitting the app does; each request returns as if cancelled.
  package func withdrawAllPrompts() {
    let waiting = state.withLock { state in
      defer { state.waiting = [] }
      return state.waiting
    }
    for item in waiting { resumeWithdrawn(item) }
  }

  // MARK: - Prompts

  /// Answers at once with what `immediate` returns, or else queues `prompt` and waits for the runtime to answer it.
  private func waitForAnswer(
    _ prompt: Prompt,
    immediate: @Sendable (inout State) -> Answer?
  ) async -> Answer {
    let id = state.withLock { state in
      defer { state.nextID += 1 }
      return state.nextID
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
        let now: Answer? = state.withLock { state in
          if let answer = immediate(&state) { return answer }
          if state.withdrawn.remove(id) != nil { return withdrawnAnswer(prompt, in: state) }
          state.waiting.append(Waiting(id: id, prompt: prompt, continuation: continuation))
          return nil
        }
        if let now { continuation.resume(returning: now) }
      }
    } onCancel: {
      withdraw(id)
    }
  }

  private func withdraw(_ id: UInt64) {
    let waiting: Waiting? = state.withLock { state in
      guard let index = state.waiting.firstIndex(where: { $0.id == id }) else {
        state.withdrawn.insert(id)
        return nil
      }
      return state.waiting.remove(at: index)
    }
    if let waiting { resumeWithdrawn(waiting) }
  }

  private func resumeWithdrawn(_ waiting: Waiting) {
    let answer = state.withLock { withdrawnAnswer(waiting.prompt, in: $0) }
    waiting.continuation.resume(returning: answer)
  }

  /// What a withdrawn request returns: the status unchanged, or a failed authentication.
  private func withdrawnAnswer(_ prompt: Prompt, in state: State) -> Answer {
    switch prompt {
    case let .permission(service): .permission(state.statuses[service] ?? .notDetermined)
    case .biometry: .biometry(.failure)
    }
  }
}

extension AgentDevice: DependencyKey {
  public static var liveValue: AgentDevice { AgentDevice() }
  public static var testValue: AgentDevice { AgentDevice() }
}

extension DependencyValues {
  /// The simulated device: what the app's permission, connectivity, location and biometry fakes read.
  public var agentDevice: AgentDevice {
    get { self[AgentDevice.self] }
    set { self[AgentDevice.self] = newValue }
  }
}
