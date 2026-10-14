import Foundation

enum PersistenceEncoding {
  private struct CoalescingKey: Hashable, Sendable {
    let owner: UUID
    let key: String
  }

  private typealias PendingJob = @Sendable () -> Void
  private struct ScheduledJob {
    let generation: UUID
    let workItem: DispatchWorkItem
  }

  static let queue = DispatchQueue(label: "com.codevisor.persistence-encode", qos: .utility)
  static let encoder = JSONEncoder()
  private static let pendingLock = NSLock()
  nonisolated(unsafe) private static var pendingJobs: [CoalescingKey: PendingJob] = [:]
  nonisolated(unsafe) private static var scheduledJobs: [CoalescingKey: ScheduledJob] = [:]

  static func enqueueLatest(
    owner: UUID,
    key: String,
    delay: TimeInterval = 0.2,
    job: @escaping @Sendable () -> Void
  ) {
    let coalescingKey = CoalescingKey(owner: owner, key: key)
    let generation = UUID()
    let workItem = DispatchWorkItem {
      runPendingJob(for: coalescingKey, generation: generation)
    }
    let previous: DispatchWorkItem? = pendingLock.withLock {
      let previous = scheduledJobs[coalescingKey]?.workItem
      pendingJobs[coalescingKey] = job
      scheduledJobs[coalescingKey] = ScheduledJob(
        generation: generation,
        workItem: workItem
      )
      return previous
    }
    previous?.cancel()
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private static func runPendingJob(for key: CoalescingKey, generation: UUID) {
    let job: PendingJob? = pendingLock.withLock {
      guard scheduledJobs[key]?.generation == generation else { return nil }
      scheduledJobs[key] = nil
      return pendingJobs.removeValue(forKey: key)
    }
    job?()
  }

  static func drain() {
    let jobs: [PendingJob] = pendingLock.withLock {
      for scheduled in scheduledJobs.values { scheduled.workItem.cancel() }
      scheduledJobs.removeAll()
      let jobs = Array(pendingJobs.values)
      pendingJobs.removeAll()
      return jobs
    }
    queue.sync(flags: .enforceQoS) {
      for job in jobs { job() }
    }
  }
}
