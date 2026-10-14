import Foundation

final class CloudChannelCreditGate: @unchecked Sendable {
  private let lock = NSLock()
  private let onWait: @Sendable () -> Void

  init(onWait: @escaping @Sendable () -> Void = {}) { self.onWait = onWait }
  private var available = 0
  private var failure: (any Error)?
  private var waiter: (required: Int, continuation: CheckedContinuation<Void, any Error>)?

  static func sealedCost(plaintextBytes: Int, compressed: Bool) -> Int {
    plaintextBytes + (compressed ? 1 : 0) + 16
  }

  func add(_ bytes: Int) {
    let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
      available += bytes
      guard let pending = waiter, pending.required <= available else { return nil }
      waiter = nil
      available -= pending.required
      return pending.continuation
    }
    resume?.resume()
  }

  func consume(_ bytes: Int) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let action: (() -> Void)? = lock.withLock {
          if let failure {
            return { continuation.resume(throwing: failure) }
          }
          let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
          if cancelled {
            return { continuation.resume(throwing: CancellationError()) }
          }
          if waiter == nil, available >= bytes {
            available -= bytes
            return { continuation.resume() }
          }
          guard waiter == nil else {
            return {
              continuation.resume(throwing: CloudRelayTransportError.invalidFrame)
            }
          }
          waiter = (bytes, continuation)
          return nil
        }
        if let action { action() } else { onWait() }
      }
    } onCancel: {
      let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
        defer { waiter = nil }
        return waiter?.continuation
      }
      resume?.resume(throwing: CancellationError())
    }
  }

  func fail(_ error: any Error) {
    let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
      if failure == nil { failure = error }
      defer { waiter = nil }
      return waiter?.continuation
    }
    resume?.resume(throwing: error)
  }
}
