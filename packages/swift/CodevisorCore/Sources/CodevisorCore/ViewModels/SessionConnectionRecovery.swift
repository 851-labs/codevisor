import Foundation

@MainActor
final class SessionConnectionRecovery {
  private nonisolated static let maximumBackoffDoublings = 5

  weak var model: SessionModel?
  private(set) var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var surfacedError: String?

  private let scheduler: SessionConnectionRecoveryScheduler
  private let retryBaseDelay: Duration
  private let retryMaximumDelay: Duration

  init(
    scheduler: SessionConnectionRecoveryScheduler,
    retryBaseDelay: Duration,
    retryMaximumDelay: Duration
  ) {
    self.scheduler = scheduler
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
    clearSurfacedError()
  }

  func clearSurfacedError() {
    guard let model else { return }

    if let surfacedError, model.errorMessage == surfacedError {
      model.errorMessage = nil
    }
    surfacedError = nil
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
    var failures = 1
    while !Task.isCancelled {
      do {
        try await scheduler.sleep(retryDelay(failures: failures))
      } catch {
        return
      }

      let outcome = await model.performReconciliationAttempt()
      guard !Task.isCancelled else { return }
      guard Self.isRetryable(outcome) else {
        finish(outcome)
        return
      }

      failures += 1
    }
  }

  private func finish(_ outcome: SessionHistoryLoadOutcome) {
    switch outcome {
    case .loaded:
      clearSurfacedError()
    case .cancelled:
      break
    case let .failed(message, _):
      surfaceFailure(message)
    }
  }

  private func surfaceFailure(_ message: String) {
    guard let model else { return }

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
