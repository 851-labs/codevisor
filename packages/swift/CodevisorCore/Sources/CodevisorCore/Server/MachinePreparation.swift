import Foundation

@MainActor
final class MachinePreparation {
  var task: Task<Void, Never>?
  var retryTask: Task<Void, Never>?
  var statusRecheckTask: Task<Void, Never>?
  var backgroundConnectInFlight = false
  private(set) var failures = 0
  private(set) var statusFailures = 0

  func nextRetryDelay(base: Duration) -> Duration {
    failures += 1
    return base * RetryBackoff.multiplier(afterFailures: failures)
  }

  func nextStatusRecheckDelay(base: Duration) -> Duration {
    statusFailures += 1
    return base * RetryBackoff.multiplier(afterFailures: statusFailures)
  }

  func cancelRetry() {
    retryTask?.cancel()
    retryTask = nil
    statusRecheckTask?.cancel()
    statusRecheckTask = nil
  }

  func resetRetries() {
    retryTask?.cancel()
    retryTask = nil
    failures = 0
  }

  func resetStatusRechecks() {
    statusRecheckTask?.cancel()
    statusRecheckTask = nil
    statusFailures = 0
  }
}
