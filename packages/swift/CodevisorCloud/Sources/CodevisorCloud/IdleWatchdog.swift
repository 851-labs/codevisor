import Foundation

final class IdleWatchdog: @unchecked Sendable {
  private let timeout: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let lock = NSLock()
  private var generation = 0
  private var frozen = false
  private var finished = false
  private var timer: Task<Void, Never>?
  private var waiter: CheckedContinuation<Void, any Error>?

  init(timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.timeout = timeout
    self.sleep = sleep
    touch()
  }

  func touch() {
    restart(freezing: false)
  }

  func freeze() {
    restart(freezing: true)
  }

  private func restart(freezing: Bool) {
    let previous: Task<Void, Never>? = lock.withLock {
      guard !frozen, !finished else { return nil }
      frozen = freezing
      generation += 1
      let current = generation
      let previous = timer
      timer = Task { [weak self, sleep, timeout] in
        do {
          try await sleep(timeout)
        } catch {
          return
        }
        self?.expire(generation: current)
      }
      return previous
    }
    previous?.cancel()
  }

  private func expire(generation fired: Int) {
    let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
      guard fired == generation, !finished else { return nil }
      finished = true
      defer { waiter = nil }
      return waiter
    }
    resume?.resume()
  }

  func waitForExpiry() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let alreadyExpired: Bool = lock.withLock {
          if finished { return true }
          waiter = continuation
          return false
        }
        if alreadyExpired { continuation.resume() }
      }
    } onCancel: {
      let (resume, timer): (CheckedContinuation<Void, any Error>?, Task<Void, Never>?) = lock.withLock {
        finished = true
        defer {
          waiter = nil
          self.timer = nil
        }
        return (waiter, self.timer)
      }
      timer?.cancel()
      resume?.resume(throwing: CancellationError())
    }
  }
}
