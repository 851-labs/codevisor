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

  private enum Waiter {
    case request(CheckedContinuation<Void, any Error>)
    case connection(CheckedContinuation<Void, any Error>)
  }

  private let lock = NSLock()
  private var states: [String: State] = [:]
  private var waiters: [String: [UUID: Waiter]] = [:]
  private var connectionLostHandler: (@Sendable (String) -> Void)?

  private let clock: any Clock<Duration>
  private let onWait: @Sendable () -> Void

  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    onWait: @escaping @Sendable () -> Void = {}
  ) {
    self.clock = clock
    self.onWait = onWait
  }

  public func onConnectionLost(_ handler: @escaping @Sendable (_ machineId: String) -> Void) {
    lock.withLock { connectionLostHandler = handler }
  }

  public func reportConnectionLost(for machineId: String) {
    let handler = lock.withLock { () -> (@Sendable (String) -> Void)? in
      guard case .ready = states[machineId] ?? .ready, let connectionLostHandler else { return nil }
      states[machineId] = .waiting
      return connectionLostHandler
    }
    handler?(machineId)
  }

  public func isWaiting(for machineId: String) -> Bool {
    lock.withLock {
      guard case .waiting = states[machineId] else { return false }
      return true
    }
  }

  public func beginWaiting(for machineId: String) {
    lock.withLock {
      states[machineId] = .waiting
    }
  }

  public func markReady(for machineId: String) {
    let released = lock.withLock {
      states[machineId] = .ready
      return Array((waiters.removeValue(forKey: machineId) ?? [:]).values)
    }
    for waiter in released {
      switch waiter {
      case let .request(continuation), let .connection(continuation): continuation.resume()
      }
    }
  }

  public func markFailed(for machineId: String, message: String) {
    let released = lock.withLock {
      states[machineId] = .failed(message)
      return releaseRequestWaiters(for: machineId)
    }
    let error = ServerRequestGateError(message: message)
    for continuation in released {
      continuation.resume(throwing: error)
    }
  }

  public func waitUntilReady(for machineId: String) async throws {
    try await wait(for: machineId) { state, continuation in
      switch state {
      case .ready: .success(())
      case let .failed(message): .failure(ServerRequestGateError(message: message))
      case .waiting: .waiting(.request(continuation))
      }
    }
  }

  public func waitUntilConnected(for machineId: String) async throws {
    try await wait(for: machineId) { state, continuation in
      guard case .ready = state else { return .waiting(.connection(continuation)) }
      return .success(())
    }
  }

  public func waitUntilReady(for machineId: String, timeout: Duration) async throws {
    try await clock.waitUntilReady(for: machineId, gate: self, timeout: timeout)
  }

  private enum Resolution {
    case success(Void)
    case failure(any Error)
    case waiting(Waiter)
  }

  private func wait(
    for machineId: String,
    resolve: @escaping (State, CheckedContinuation<Void, any Error>) -> Resolution
  ) async throws {
    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let resolution: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          switch resolve(states[machineId] ?? .ready, continuation) {
          case .success: return .success(())
          case let .failure(error): return .failure(error)
          case let .waiting(waiter):
            waiters[machineId, default: [:]][waiterId] = waiter
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
      let waiter = self.lock.withLock { self.waiters[machineId]?.removeValue(forKey: waiterId) }
      switch waiter {
      case let .request(continuation), let .connection(continuation):
        continuation.resume(throwing: CancellationError())
      case nil: break
      }
    }
  }

  private func releaseRequestWaiters(for machineId: String) -> [CheckedContinuation<Void, any Error>] {
    var released: [CheckedContinuation<Void, any Error>] = []
    for (id, waiter) in waiters[machineId] ?? [:] {
      guard case let .request(continuation) = waiter else { continue }
      released.append(continuation)
      waiters[machineId]?.removeValue(forKey: id)
    }
    return released
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
