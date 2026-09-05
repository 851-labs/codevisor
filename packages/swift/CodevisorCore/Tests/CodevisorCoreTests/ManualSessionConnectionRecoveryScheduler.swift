import Observation
import Foundation
@testable import CodevisorCore

@MainActor
@Observable
final class ManualSessionConnectionRecoveryScheduler {
  private struct PendingSleep {
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var current = ContinuousClock.now
  private var nextID = 0
  private var pending: [Int: PendingSleep] = [:]
  private(set) var requestedIntervals: [Duration] = []

  var pendingCount: Int { pending.count }

  @ObservationIgnored lazy var scheduler = SessionConnectionRecoveryScheduler(
    now: { [weak self] in self?.current ?? ContinuousClock.now },
    sleep: { [weak self] interval in
      guard let self else { throw CancellationError() }
      try await self.sleep(for: interval)
    }
  )

  func advance() {
    guard let deadline = pending.values.map(\.deadline).min() else { return }
    current = deadline
    let ready =
      pending
      .filter { $0.value.deadline <= deadline }
      .sorted { $0.key < $1.key }
    for (id, sleep) in ready {
      pending[id] = nil
      sleep.continuation.resume()
    }
  }

  private func sleep(for interval: Duration) async throws {
    try Task.checkCancellation()
    nextID += 1
    let id = nextID
    requestedIntervals.append(interval)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = PendingSleep(
          deadline: current.advanced(by: interval),
          continuation: continuation
        )
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(id)
      }
    }
  }

  private func cancel(_ id: Int) {
    guard let sleep = pending.removeValue(forKey: id) else { return }
    sleep.continuation.resume(throwing: CancellationError())
  }
}
