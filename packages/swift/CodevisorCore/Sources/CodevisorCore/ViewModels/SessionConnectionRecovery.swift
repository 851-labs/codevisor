import Foundation

@MainActor
final class SessionConnectionRecovery {
  private nonisolated static let maximumBackoffDoublings = 5
  private static let reconnectingMessage = "Reconnecting…"

  weak var model: SessionModel?
  private(set) var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var surfacedError: String?

  private let scheduler: SessionConnectionRecoveryScheduler
  private let statusDelay: Duration
  private let retryBaseDelay: Duration
  private let retryMaximumDelay: Duration

  init(
    scheduler: SessionConnectionRecoveryScheduler,
    statusDelay: Duration,
    retryBaseDelay: Duration,
    retryMaximumDelay: Duration
  ) {
    self.scheduler = scheduler
    self.statusDelay = statusDelay
    self.retryBaseDelay = retryBaseDelay
    self.retryMaximumDelay = retryMaximumDelay
  }

  var isRunning: Bool { task != nil }

  func reconcile() async {
    guard task == nil else { return }

    generation &+= 1
    let task = firstAttempt(generation: generation)
    self.task = task
    await task.value
  }

  func cancelAndWait() async {
    guard let task else { return }

    task.cancel()
    await task.value
    self.task = nil
  }

  func stop() {
    generation &+= 1
    task?.cancel()
    task = nil
    clearPresentation()
  }

  func clearPresentation() {
    guard let model else { return }

    model.connectionRecoveryMessage = model.synchronizationMessage
    if let surfacedError, model.errorMessage == surfacedError {
      model.errorMessage = nil
    }
    surfacedError = nil
  }

  func streamReconnectNoticeChanged(isVisible: Bool) {
    guard let model else { return }

    if isVisible {
      if model.connectionRecoveryMessage == nil { model.connectionRecoveryMessage = model.synchronizationMessage }
    } else if task == nil, surfacedError == nil {
      model.connectionRecoveryMessage = nil
    }
  }

  private func firstAttempt(generation: UInt64) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      guard let self, let model = self.model else { return }
      var handedOffRetry = false
      defer {
        if !handedOffRetry, self.generation == generation { self.task = nil }
        withExtendedLifetime(model) {}
      }

      let outcome = await model.performReconciliationAttempt()
      guard !Task.isCancelled else { return }
      guard Self.isRetryable(outcome) else {
        self.finish(outcome)
        return
      }

      handedOffRetry = true
      self.task = self.retryLoop(generation: generation)
    }
  }

  private func retryLoop(generation: UInt64) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      guard let self, let model = self.model else { return }
      defer {
        if self.generation == generation { self.task = nil }
        withExtendedLifetime(model) {}
      }

      await self.retryUntilSettled(model)
    }
  }

  private func retryUntilSettled(_ model: SessionModel) async {
    let startedAt = scheduler.now()
    var failures = 1
    var nextAttemptAt = startedAt.advanced(by: retryDelay(failures: failures))

    while !Task.isCancelled {
      let now = scheduler.now()
      let elapsed = now - startedAt
      announceReconnecting(model, elapsed: elapsed)

      if now < nextAttemptAt {
        let wait = sleepInterval(model, untilAttempt: now.duration(to: nextAttemptAt), elapsed: elapsed)
        do {
          try await scheduler.sleep(wait)
        } catch {
          return
        }
        continue
      }

      let outcome = await model.performReconciliationAttempt()
      guard !Task.isCancelled else { return }
      guard Self.isRetryable(outcome) else {
        finish(outcome)
        return
      }

      failures += 1
      nextAttemptAt = scheduler.now().advanced(by: retryDelay(failures: failures))
    }
  }

  private func finish(_ outcome: SessionHistoryLoadOutcome) {
    switch outcome {
    case .loaded:
      clearPresentation()
    case .cancelled:
      break
    case let .failed(message, _):
      surfaceFailure(message)
    }
  }

  private func announceReconnecting(_ model: SessionModel, elapsed: Duration) {
    guard elapsed >= statusDelay, model.connectionRecoveryMessage == nil else { return }

    model.connectionRecoveryMessage = Self.reconnectingMessage
  }

  private func sleepInterval(_ model: SessionModel, untilAttempt: Duration, elapsed: Duration) -> Duration {
    guard isQuiet(model), elapsed < statusDelay else { return untilAttempt }

    return min(untilAttempt, statusDelay - elapsed)
  }

  private func isQuiet(_ model: SessionModel) -> Bool {
    model.connectionRecoveryMessage == nil && surfacedError == nil
  }

  private func surfaceFailure(_ message: String) {
    guard let model else { return }

    model.connectionRecoveryMessage = model.synchronizationMessage
    let previous = surfacedError
    surfacedError = message
    if model.errorMessage == nil || model.errorMessage == previous {
      model.errorMessage = message
    }
  }

  private nonisolated func retryDelay(failures: Int) -> Duration {
    let multiplier = 1 << min(max(failures - 1, 0), Self.maximumBackoffDoublings)
    return min(retryMaximumDelay, retryBaseDelay * multiplier)
  }

  private nonisolated static func isRetryable(_ outcome: SessionHistoryLoadOutcome) -> Bool {
    guard case .failed(_, retryable: true) = outcome else { return false }
    return true
  }
}
