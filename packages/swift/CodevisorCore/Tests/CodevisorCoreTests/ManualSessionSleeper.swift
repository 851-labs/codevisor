import Foundation

/// A cancellation-aware, manually advanced replacement for `Task.sleep`.
/// Tests can observe every new timer generation without depending on elapsed
/// wall time or executor load.
@MainActor
final class ManualSessionSleeper {
    private struct CallWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var activeSleeps: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var callWaiters: [CallWaiter] = []
    private(set) var callCount = 0

    func sleep(for _: Duration) async throws {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        activeSleeps[id] = continuation
        callCount += 1
        resumeSatisfiedCallWaiters()

        await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            continuation.finish()
        }

        activeSleeps[id] = nil
        try Task.checkCancellation()
    }

    func waitForCallCount(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(CallWaiter(target: target, continuation: continuation))
        }
    }

    func advance() {
        let continuations = Array(activeSleeps.values)
        activeSleeps.removeAll()
        for continuation in continuations {
            continuation.yield(())
            continuation.finish()
        }
    }

    func cancelAll() {
        let continuations = Array(activeSleeps.values)
        activeSleeps.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { $0.target <= callCount }
        callWaiters.removeAll { $0.target <= callCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
