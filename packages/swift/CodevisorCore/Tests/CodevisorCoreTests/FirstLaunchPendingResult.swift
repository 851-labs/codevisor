import Foundation
import Synchronization

final class FirstLaunchPendingResult<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, any Error>?
    var waiters: [Int: CheckedContinuation<Value, any Error>] = [:]
    var nextWaiter = 0
  }

  private let state = Mutex(State())

  func resolve(_ value: Value) {
    finish(.success(value))
  }

  func fail() {
    finish(.failure(FirstLaunchFakeFailure()))
  }

  func value() async throws -> Value {
    let id = state.withLock { state in
      state.nextWaiter += 1
      return state.nextWaiter
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let settled = state.withLock { state -> Result<Value, any Error>? in
          if Task.isCancelled { return .failure(CancellationError()) }
          if let result = state.result { return result }
          state.waiters[id] = continuation
          return nil
        }
        if let settled { continuation.resume(with: settled) }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.resume(throwing: CancellationError())
    }
  }

  private func finish(_ result: Result<Value, any Error>) {
    let waiters = state.withLock { state in
      state.result = result
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    waiters.forEach { $0.resume(with: result) }
  }
}
