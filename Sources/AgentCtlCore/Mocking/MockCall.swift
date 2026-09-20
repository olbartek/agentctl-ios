import Dependencies

/// The single shim every mock backend method goes through.
///
/// It records the call in ``MockCallLog``, waits the ``MockLatency`` (never touching the clock when it is zero),
/// throws a fault registered in ``MockFaults`` if there is one, and otherwise runs `body`.
///
/// - Parameters:
///   - name: `"<client>.<method>"`, e.g. `items.fetch`.
///   - makeError: Turns a fault code (e.g. `network`) into the client's typed error.
public func mockCall<T: Sendable>(
  _ name: String,
  error makeError: @Sendable (String) -> any Error,
  _ body: @Sendable () async throws -> T
) async throws -> T {
  @Dependency(\.mockCallLog) var log
  @Dependency(\.mockFaults) var faults
  @Dependency(\.mockLatency) var latency
  @Dependency(\.continuousClock) var clock
  @Dependency(\.withRandomNumberGenerator) var randomNumberGenerator

  log.begin(name)
  defer { log.end(name) }
  let delay = latency.sample(using: randomNumberGenerator)
  if delay > .zero {
    try await clock.sleep(for: delay)
  }
  if let code = faults.take(name) {
    throw makeError(code)
  }
  return try await body()
}

/// A mock method that can be made to fail with `mock <name> <code>`: its name and the error codes it accepts.
public struct MockMethod: Equatable, Hashable, Sendable {
  public var name: String
  public var errorCodes: [String]

  public init(_ name: String, errorCodes: [String]) {
    self.name = name
    self.errorCodes = errorCodes
  }
}
