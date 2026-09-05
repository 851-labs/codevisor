import Foundation

/// Virtual elapsed time with explicit registration and cancellation barriers.
public final class TestClock: @unchecked Sendable {
  private struct Sleeper {
    let duration: Duration
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private let origin = ContinuousClock.now
  private var elapsed: Duration = .zero
  private var pending: [Int: Sleeper] = [:]
  private var requests: [Duration] = []
  private var nextID = 0
  public let changed = TestSignal()

  public init() {}

  public var now: ContinuousClock.Instant { lock.withLock { origin + elapsed } }

  public var pendingCount: Int { lock.withLock { pending.count } }

  public func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    if duration <= .zero { return }
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let cancelled = lock.withLock {
          if Task.isCancelled { return true }
          requests.append(duration)
          pending[id] = Sleeper(duration: duration, deadline: elapsed + duration, continuation: continuation)
          return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        changed.signal()
      }
    } onCancel: {
      let sleeper = self.lock.withLock { self.pending.removeValue(forKey: id) }
      sleeper?.continuation.resume(throwing: CancellationError())
      self.changed.signal()
    }
  }

  public func waitForSleep(_ duration: Duration, count: Int = 1) async {
    while true {
      let revision = changed.value
      if lock.withLock({
        requests.filter { $0 == duration }.count >= count
          && pending.values.contains { $0.duration == duration }
      }) {
        return
      }
      await changed.wait(for: revision + 1)
    }
  }

  public func advance(by duration: Duration) {
    let ready = lock.withLock {
      elapsed += duration
      let ready = pending.filter { $0.value.deadline <= elapsed }.sorted { $0.key < $1.key }
      for (id, _) in ready { pending.removeValue(forKey: id) }
      return ready
    }
    for (_, sleeper) in ready { sleeper.continuation.resume() }
    changed.signal()
  }
}
