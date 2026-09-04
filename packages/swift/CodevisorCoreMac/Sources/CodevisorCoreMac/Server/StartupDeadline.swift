import Foundation

enum StartupDeadlineError: Error, LocalizedError {
  case expired
  var errorDescription: String? { "The server did not respond before the request deadline." }
}

/// A timeout must return even when an underlying operation ignores cancellation.
/// Only the winning task can resume the caller; late responses cannot advance startup.
@MainActor
enum StartupDeadline {
  static func run<Value: Sendable>(
    for timeout: Duration,
    operation: @escaping @MainActor @Sendable () async throws -> Value
  ) async throws -> Value {
    let outcome = StartupOutcome<Value>()
    let worker = Task { @MainActor in
      do { outcome.resolve(.success(try await operation())) } catch { outcome.resolve(.failure(error)) }
    }
    let timer = Task {
      do {
        try await Task.sleep(for: timeout)
        outcome.resolve(.failure(StartupDeadlineError.expired))
      } catch { /* The operation finished first. */  }
    }
    defer { worker.cancel(); timer.cancel() }
    return try await withTaskCancellationHandler {
      try await outcome.value
    } onCancel: {
      outcome.resolve(.failure(CancellationError()))
    }
  }
}

private final class StartupOutcome<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?

  var value: Value {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let result {
          lock.unlock()
          continuation.resume(with: result)
        } else {
          self.continuation = continuation
          lock.unlock()
        }
      }
    }
  }

  func resolve(_ result: Result<Value, any Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume(with: result)
  }
}
