import Foundation

/// A serial background queue that runs only the newest pending job per key.
///
/// Main-actor owners hand it the encoding and file writes a state change
/// needs, so the main thread never waits on the disk. Jobs run one at a
/// time, in the order their keys were first enqueued; a job replaced before
/// it starts never runs, so a burst of saves for one key (a progress report
/// per download chunk, a backup per typing pause) costs at most one write in
/// flight plus the latest. Because the queue is serial, the newest job for a
/// key always lands last: a final state can never be overwritten by an
/// older one.
///
/// `perform` runs after every job enqueued before it, which gives ordered
/// reads (a load sees earlier saves) and an awaitable flush.
public final class CoalescingWorkQueue: @unchecked Sendable {
  public typealias Job = @Sendable () -> Void

  private let queue: DispatchQueue
  private let lock = NSLock()
  /// Newest not-yet-started job per key. A key present here already has a
  /// block scheduled on `queue` that will run whatever job it holds then.
  private var pending: [String: Job] = [:]

  public init(label: String, qos: DispatchQoS = .utility) {
    queue = DispatchQueue(label: label, qos: qos)
  }

  /// Schedules `job`, replacing any job for `key` that has not started yet.
  public func enqueue(key: String, _ job: @escaping Job) {
    let needsSchedule = lock.withLock {
      let scheduled = pending[key] != nil
      pending[key] = job
      return !scheduled
    }
    guard needsSchedule else { return }
    queue.async { [self] in
      let job = lock.withLock { pending.removeValue(forKey: key) }
      job?()
    }
  }

  /// Runs `body` on the queue after every job enqueued so far, suspending
  /// (not blocking) the caller until it returns.
  public func perform<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: body()) }
    }
  }

  /// Waits, without blocking the caller's thread, until every job enqueued
  /// so far has run.
  public func flush() async {
    await perform {}
  }
}
