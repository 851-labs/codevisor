import Foundation

public enum ServerWaitingReason: Equatable, Sendable {
  case starting
  case connecting
  case updating
  case restarting
}

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

public final class ServerRequestGate: @unchecked Sendable {
  private enum State {
    case ready
    case waiting
    case failed(String)
  }

  private let lock = NSLock()
  private var states: [String: State] = [:]
  private var waiters: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

  private let clock: any Clock<Duration>
  private let onWait: @Sendable () -> Void

  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    onWait: @escaping @Sendable () -> Void = {}
  ) {
    self.clock = clock
    self.onWait = onWait
  }

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
        } else {
          onWait()
        }
      }
    } onCancel: {
      let continuation = self.lock.withLock {
        self.waiters[machineId]?.removeValue(forKey: waiterId)
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  public func waitUntilReady(for machineId: String, timeout: Duration) async throws {
    try await clock.waitUntilReady(for: machineId, gate: self, timeout: timeout)
  }
}

private extension Clock where Duration == Swift.Duration {
  func waitUntilReady(for machineId: String, gate: ServerRequestGate, timeout: Duration) async throws {
    let deadline = now.advanced(by: timeout)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await gate.waitUntilReady(for: machineId)
      }
      group.addTask {
        try await sleep(until: deadline, tolerance: nil)
        throw ServerRequestGateError(
          message: "Timed out waiting for the server to become ready."
        )
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
}
