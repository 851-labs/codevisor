import Foundation

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
  private static let firstConnectionRetryDelay: Duration = .milliseconds(500)
  private static let connectionRetryCeiling: Duration = .seconds(2)
  private let sleep: @MainActor (Duration) async throws -> Void
  var isRunning: Bool { attempt != nil }

  init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.sleep = sleep
  }

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
      var retryDelay = Self.firstConnectionRetryDelay
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
          guard ServerConnectionLoss.isConnectionLoss(error) else {
            onEvent(.failed(serverErrorMessage(error)))
            return
          }
          onEvent(.waitingForServer)
          try? await sleep(retryDelay)
          retryDelay = min(retryDelay * 2, Self.connectionRetryCeiling)
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
