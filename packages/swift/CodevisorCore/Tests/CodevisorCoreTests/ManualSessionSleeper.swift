import Foundation

/// A cancellation-aware, manually advanced replacement for `Task.sleep`.
/// Tests can observe every new timer generation without depending on elapsed
/// wall time or executor load. Continuations are removed under one lock before
/// they are resumed, so cancellation and advancement cannot finish the same
/// sleep concurrently.
final class ManualSessionSleeper: @unchecked Sendable {
    private struct CallWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var activeSleeps: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var callWaiters: [CallWaiter] = []
    private var callCount = 0

    func sleep(for _: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let satisfied = lock.withLock {
                    activeSleeps[id] = continuation
                    callCount += 1
                    let ready = callWaiters.filter { $0.target <= callCount }
                    callWaiters.removeAll { $0.target <= callCount }
                    return ready
                }
                for waiter in satisfied {
                    waiter.continuation.resume()
                }
                // Cancellation can arrive before the continuation is stored.
                // Re-check after registration so that race cannot strand it.
                if Task.isCancelled {
                    cancel(id)
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    func waitForCallCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard callCount < target else { return true }
                callWaiters.append(CallWaiter(target: target, continuation: continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func advance() {
        let continuations = lock.withLock {
            let pending = Array(activeSleeps.values)
            activeSleeps.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func cancelAll() {
        let continuations = lock.withLock {
            let pending = Array(activeSleeps.values)
            activeSleeps.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock {
            activeSleeps.removeValue(forKey: id)
        }
        continuation?.resume(throwing: CancellationError())
    }
}
