import Foundation

/// Outbound budget for one flow-controlled channel: `consume` suspends until
/// the peer has granted enough ciphertext bytes, so a sender can never put
/// more than the peer's window in flight. One sequential sender per gate
/// (both relay transports send from a single task); `fail` releases any
/// waiter when the channel dies.
final class CloudChannelCreditGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = 0
    private var failure: (any Error)?
    private var waiter: (required: Int, continuation: CheckedContinuation<Void, any Error>)?

    /// The exact ciphertext cost of sending `plaintextBytes` from this side:
    /// the app never DEFLATEs, so a negotiated-compression channel adds one
    /// RAW framing byte, and the AEAD adds its 16-byte tag.
    static func sealedCost(plaintextBytes: Int, compressed: Bool) -> Int {
        plaintextBytes + (compressed ? 1 : 0) + 16
    }

    /// Books a peer grant, waking the waiter if its requirement is now met.
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

    /// Waits until `bytes` of budget is available and consumes it. Honors
    /// task cancellation — a timed-out request must not park here forever.
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
                        // Two concurrent senders would deadlock each other;
                        // the transports are single-sender by construction.
                        return {
                            continuation.resume(throwing: CloudRelayTransportError.invalidFrame)
                        }
                    }
                    waiter = (bytes, continuation)
                    return nil
                }
                action?()
            }
        } onCancel: {
            // Only the waiter's own task cancels it (single-sender), so
            // releasing "the" waiter is releasing ourselves.
            let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
                defer { waiter = nil }
                return waiter?.continuation
            }
            resume?.resume(throwing: CancellationError())
        }
    }

    /// The channel died: pending and future consumers fail with `error`.
    func fail(_ error: any Error) {
        let resume: CheckedContinuation<Void, any Error>? = lock.withLock {
            if failure == nil { failure = error }
            defer { waiter = nil }
            return waiter?.continuation
        }
        resume?.resume(throwing: error)
    }
}
