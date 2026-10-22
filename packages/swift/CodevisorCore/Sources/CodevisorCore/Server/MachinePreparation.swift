import Foundation

@MainActor
final class MachinePreparation {
  var task: Task<Void, Never>?
  var retryTask: Task<Void, Never>?
  var backgroundConnectInFlight = false
  private(set) var failures = 0

  func nextRetryDelay(base: Duration) -> Duration {
    failures += 1
    return base * RetryBackoff.multiplier(afterFailures: failures)
  }

  func cancelRetry() {
    retryTask?.cancel()
    retryTask = nil
  }

  func resetRetries() {
    cancelRetry()
    failures = 0
  }
}
