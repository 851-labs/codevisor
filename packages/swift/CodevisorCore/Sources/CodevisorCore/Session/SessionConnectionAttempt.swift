import Foundation

/// Owns an eager connection beyond any individual view mount. Explicit supersession cancels and joins it.
@MainActor
final class SessionConnectionAttempt {
  enum Event {
    case starting(String)
    case waitingForServer
    case connected
    case cancelled
    case failed(String)
    case settled
  }

  private var attempt: Task<Void, Never>?
  private static let serverWaitFailureThreshold: Duration = .seconds(10)
  private static let serverWaitRetryInterval: Duration = .milliseconds(500)
  var isRunning: Bool { attempt != nil }

  func start(
    harnessName: String,
    connect: @escaping @MainActor () async throws -> Void,
    onEvent: @escaping @MainActor (Event) -> Void
  ) {
    guard attempt == nil else { return }
    attempt = Task {
      defer {
        onEvent(.settled)
        attempt = nil
      }
      onEvent(.starting(harnessName))
      let clock = ContinuousClock()
      let start = clock.now
      while true {
        do {
          try await connect()
          onEvent(.connected)
          return
        } catch {
          guard !isTaskCancellation(error) else {
            onEvent(.cancelled)
            return
          }
          let message = serverErrorMessage(error)
          let elapsed = clock.now - start
          guard message == serverUnreachableErrorMessage,
            elapsed < Self.serverWaitFailureThreshold
          else {
            onEvent(.failed(message))
            return
          }
          onEvent(.waitingForServer)
          try? await Task.sleep(for: Self.serverWaitRetryInterval)
          guard !Task.isCancelled else {
            onEvent(.cancelled)
            return
          }
        }
      }
    }
  }

  func waitForCompletion() async { await attempt?.value }

  func cancelAndWait() async {
    guard let attempt else { return }
    attempt.cancel()
    await attempt.value
  }
}
