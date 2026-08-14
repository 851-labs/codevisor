import Foundation

/// Why normal server-backed UI is temporarily waiting. The reason is kept in
/// shared core so macOS and iOS render the same lifecycle vocabulary.
public enum ServerWaitingReason: Equatable, Sendable {
    case starting
    case connecting
    case updating
    case restarting
}

/// The selected machine's ability to serve ordinary application requests.
/// Health/status, startup, shutdown, and update requests use an ungated
/// lifecycle path and drive this state.
public enum ServerAvailability: Equatable, Sendable {
    case waiting(ServerWaitingReason)
    case ready
    case failed(String)
}

public struct ServerRequestGateError: Error, LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A synchronous-state, asynchronous-wait gate shared by every concrete
/// client for a machine. Requests that have not yet been dispatched wait here
/// while a known startup/restart is in progress. This deliberately does not
/// retry a request after URLSession has dispatched it: mutation outcomes can
/// be ambiguous after a connection loss.
public final class ServerRequestGate: @unchecked Sendable {
    private enum State {
        case ready
        case waiting
        case failed(String)
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    public init() {}

    public func beginWaiting(for machineId: String) {
        lock.withLock {
            states[machineId] = .waiting
        }
    }

    public func markReady(for machineId: String) {
        let continuations = lock.withLock {
            states[machineId] = .ready
            let pending = waiters.removeValue(forKey: machineId) ?? [:]
            return Array(pending.values)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    public func markFailed(for machineId: String, message: String) {
        let continuations = lock.withLock {
            states[machineId] = .failed(message)
            let pending = waiters.removeValue(forKey: machineId) ?? [:]
            return Array(pending.values)
        }
        let error = ServerRequestGateError(message: message)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    public func waitUntilReady(for machineId: String) async throws {
        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolution: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    switch states[machineId] ?? .ready {
                    case .ready:
                        return .success(())
                    case let .failed(message):
                        return .failure(ServerRequestGateError(message: message))
                    case .waiting:
                        waiters[machineId, default: [:]][waiterId] = continuation
                        return nil
                    }
                }
                if let resolution {
                    continuation.resume(with: resolution)
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.waiters[machineId]?.removeValue(forKey: waiterId)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
