import Foundation

/// Virtual elapsed time with explicit registration and cancellation barriers.
public final class TestClock: Clock, @unchecked Sendable {
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
  public var minimumResolution: Duration { .nanoseconds(1) }

  public var pendingCount: Int { lock.withLock { pending.count } }

  public func sleep(for duration: Duration) async throws {
    try await sleep(for: duration, until: nil)
  }

  public func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    try await sleep(for: .zero, until: deadline)
  }

  private func sleep(for duration: Duration, until deadline: ContinuousClock.Instant?) async throws {
    try Task.checkCancellation()
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var alreadyElapsed = false
        let cancelled = lock.withLock {
          if Task.isCancelled { return true }
          // Resolve absolute deadlines under the same lock as registration;
          // an advance before the timer starts must not extend its deadline.
          let duration = deadline.map { origin.duration(to: $0) - elapsed } ?? duration
          if duration <= .zero {
            alreadyElapsed = true
            return false
          }
          requests.append(duration)
          pending[id] = Sleeper(duration: duration, deadline: elapsed + duration, continuation: continuation)
          return false
        }
        if cancelled {
          continuation.resume(throwing: CancellationError())
        } else if alreadyElapsed {
          continuation.resume()
        }
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
