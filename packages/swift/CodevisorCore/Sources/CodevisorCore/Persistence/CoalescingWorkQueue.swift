import Foundation

public final class CoalescingWorkQueue: @unchecked Sendable {
  public typealias Job = @Sendable () -> Void

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var pending: [String: Job] = [:]

  public init(label: String, qos: DispatchQoS = .utility) {
    queue = DispatchQueue(label: label, qos: qos)
  }

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

  public func perform<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: body()) }
    }
  }

  public func flush() async {
    await perform {}
  }
}
