import Foundation

public final class TestSignal: @unchecked Sendable {
  private struct Waiter {
    let target: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private let lock = NSLock()
  private var count = 0
  private var nextWaiter = 0
  private var waiters: [Int: Waiter] = [:]

  public init() {}

  public var value: Int { lock.withLock { count } }

  public func signal() {
    let ready = lock.withLock {
      count += 1
      let ready = waiters.filter { $0.value.target <= count }.sorted { $0.key < $1.key }
      for (id, _) in ready { waiters.removeValue(forKey: id) }
      return ready.map(\.value)
    }
    for waiter in ready { waiter.continuation.resume() }
  }

  public func wait(for target: Int = 1) async {
    let id = reserveWaiter()
    await withCheckedContinuation { continuation in
      enqueue(id, target: target, endsOnCancellation: false, continuation)
    }
  }

  public func cancellableWait(for target: Int = 1) async {
    let id = reserveWaiter()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        enqueue(id, target: target, endsOnCancellation: true, continuation)
      }
    } onCancel: {
      lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }

  private func reserveWaiter() -> Int {
    lock.withLock {
      nextWaiter += 1
      return nextWaiter
    }
  }

  private func enqueue(
    _ id: Int, target: Int, endsOnCancellation: Bool, _ continuation: CheckedContinuation<Void, Never>
  ) {
    let ready = lock.withLock {
      if count >= target || (endsOnCancellation && Task.isCancelled) { return true }
      waiters[id] = Waiter(target: target, continuation: continuation)
      return false
    }
    if ready { continuation.resume() }
  }
}
