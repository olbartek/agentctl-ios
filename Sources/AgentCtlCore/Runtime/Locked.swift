import os

/// `Synchronization.Mutex` for an iOS 16 floor: the same `withLock`, typed throws included, over an unfair lock.
package final class Locked<Value>: @unchecked Sendable {
  // Every read and write of `value` goes through `lock`.
  private var value: Value
  private let lock = OSAllocatedUnfairLock()

  package init(_ value: Value) {
    self.value = value
  }

  package func withLock<Result, Failure: Error>(
    _ body: (inout Value) throws(Failure) -> Result
  ) throws(Failure) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
