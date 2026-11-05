import Foundation

@MainActor
final class MachineReconnector {
  enum Outcome: Equatable {
    case connected
    case failed
    case busy(retryAfter: Duration)
  }

  typealias Attempt = @MainActor () async -> Outcome

  static let baseDelay: Duration = .seconds(1)
  static let maximumDelay: Duration = .seconds(15)
  static let stableConnection: Duration = .seconds(30)

  var attempt: Attempt?
  private let scheduler: SessionConnectionRecoveryScheduler
  private var attemptTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var failures = 0
  private var connectedAt: ContinuousClock.Instant?
  private(set) var wasLostDuringAttempt = false

  init(scheduler: SessionConnectionRecoveryScheduler) {
    self.scheduler = scheduler
  }

  var isActive: Bool { attemptTask != nil || retryTask != nil }
  var isAttempting: Bool { attemptTask != nil }

  func connect() async {
    if let attemptTask {
      await attemptTask.value
      return
    }
    cancelRetry()
    let task = Task { await self.runAttempt() }
    attemptTask = task
    await task.value
  }

  func connectionLost() {
    if isAttempting { wasLostDuringAttempt = true }
    guard !isActive else { return }

    countLoss()
    if failures == 0 {
      Task { await connect() }
    } else {
      scheduleRetry(after: delay(afterFailures: failures))
    }
  }

  func nudge() {
    failures = 0
    guard attemptTask == nil, retryTask != nil else { return }

    Task { await connect() }
  }

  func stop() {
    cancelRetry()
    attemptTask?.cancel()
    attemptTask = nil
  }

  private func runAttempt() async {
    wasLostDuringAttempt = false
    let outcome = await attempt?() ?? .failed
    attemptTask = nil
    guard !Task.isCancelled else { return }

    switch outcome {
    case .connected:
      connectedAt = scheduler.now()
    case .failed:
      failures += 1
      scheduleRetry(after: delay(afterFailures: failures))
    case let .busy(retryAfter):
      scheduleRetry(after: retryAfter)
    }
  }

  private func countLoss() {
    guard let connectedAt else { return }

    let lasted = connectedAt.duration(to: scheduler.now())
    failures = lasted < Self.stableConnection ? failures + 1 : 0
    self.connectedAt = nil
  }

  private func scheduleRetry(after delay: Duration) {
    cancelRetry()
    let sleep = scheduler.sleep
    retryTask = Task { [weak self] in
      guard (try? await sleep(delay)) != nil, let self, !Task.isCancelled else { return }
      self.retryTask = nil
      await self.connect()
    }
  }

  private func cancelRetry() {
    retryTask?.cancel()
    retryTask = nil
  }

  private func delay(afterFailures failures: Int) -> Duration {
    let doublings = min(max(failures - 1, 0), 4)
    return min(Self.maximumDelay, Self.baseDelay * (1 << doublings))
  }
}
