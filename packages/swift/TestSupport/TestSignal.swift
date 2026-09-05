import Foundation

/// A buffered event counter. A signal cannot be lost between checking state
/// and suspending, and waiting does not depend on scheduler speed.
public final class TestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  public init() {}

  public var value: Int { lock.withLock { count } }

  public func signal() {
    let ready = lock.withLock {
      count += 1
      let ready = waiters.filter { $0.0 <= count }
      waiters.removeAll { $0.0 <= count }
      return ready
    }
    for (_, continuation) in ready { continuation.resume() }
  }

  public func wait(for target: Int = 1) async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        if count >= target { return true }
        waiters.append((target, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }
}
