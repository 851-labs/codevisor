import Foundation

/// A `Codable`-array repository backed by a `PersistenceStore`.
public struct CodableRepository<Element: Codable & Sendable>: Sendable {
  private let store: any PersistenceStore
  private let key: String
  /// Banner title shown when the persisted payload fails to decode; nil keeps
  /// corruption log-and-quarantine only.
  private let corruptionTitle: String?

  public init(store: any PersistenceStore, key: String, corruptionTitle: String? = nil) {
    self.store = store
    self.key = key
    self.corruptionTitle = corruptionTitle
  }

  public func load() -> [Element] {
    // Read-your-writes: saves encode on the shared serial queue, so drain
    // it before reading. Loads happen at startup/model construction, so
    // this barrier waits on at most a couple of in-flight encodes.
    PersistenceEncoding.drain()
    guard let data = store.loadData(forKey: key) else { return [] }
    do {
      return try JSONDecoder().decode([Element].self, from: data)
    } catch {
      handleCorruptPayload(
        store: store,
        key: key,
        data: data,
        error: error,
        reportTitle: corruptionTitle,
        reportMessage: "The file was unreadable. A backup was saved in Codevisor's data folder."
      )
      return []
    }
  }

  public func save(_ elements: [Element]) {
    // Encode off the caller's thread. Session/project mutations persist
    // from dozens of main-actor call sites — several times per second
    // during server event bursts — and the full-array encode was the only
    // main-thread piece left (the store already coalesces disk writes).
    // The serial queue preserves save ordering per key; the store's
    // per-key pending slot then keeps only the newest bytes.
    let store = store
    let key = key
    PersistenceEncoding.queue.async {
      do {
        try store.saveData(PersistenceEncoding.encoder.encode(elements), forKey: key)
      } catch {
        Log.persistence.error(
          "Failed to save \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
  }
}

/// Shared off-main encode context for repository saves. A single serial queue
/// keeps cross-repository ordering deterministic and one reused encoder
/// avoids a fresh `JSONEncoder` allocation per save. The encoder is only ever
/// touched from this queue.
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

  /// Coalesces hot state snapshots before they are encoded. Composer text
  /// can change once per keystroke; only the newest complete snapshot needs
  /// to reach SQLite. The delay happens on the persistence queue, never the
  /// main actor, and `drain()` promotes every pending job immediately for
  /// read-your-writes and lifecycle flushes.
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

  /// Blocks until every save enqueued so far has handed its bytes to the
  /// store, restoring the synchronous save→load contract for readers.
  static func drain() {
    let jobs: [PendingJob] = pendingLock.withLock {
      for scheduled in scheduledJobs.values { scheduled.workItem.cancel() }
      scheduledJobs.removeAll()
      let jobs = Array(pendingJobs.values)
      pendingJobs.removeAll()
      return jobs
    }
    // `.enforceQoS` propagates the caller's QoS (user-interactive when
    // called from the main thread) to this block and boosts any encodes
    // already queued ahead of it, avoiding a priority inversion against
    // the queue's background `.utility` QoS.
    queue.sync(flags: .enforceQoS) {
      for job in jobs { job() }
    }
  }
}
