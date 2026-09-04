import Foundation
@testable import CodevisorCoreMac

@MainActor
final class AdvancingLocalServerScheduler {
  private let start = ContinuousClock.now
  private(set) var elapsed: Duration = .zero
  private(set) var requestedIntervals: [Duration] = []
  var onSleep: () -> Void = {}
  private var timers: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]

  var scheduler: LocalServerScheduler {
    LocalServerScheduler(
      now: { self.start + self.elapsed },
      sleep: { interval in
        try Task.checkCancellation()
        self.requestedIntervals.append(interval)
        self.onSleep()
        self.advance(by: interval)
      },
      sleepUntil: { try await self.wait(until: $0) }
    )
  }

  func advance(by duration: Duration) {
    elapsed += duration
    let ready = timers.filter { $0.value.0 <= start + elapsed }
    for (id, timer) in ready {
      timers.removeValue(forKey: id)
      timer.1.resume()
    }
  }

  private func wait(until deadline: ContinuousClock.Instant) async throws {
    try Task.checkCancellation()
    guard deadline > start + elapsed else { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { timers[id] = (deadline, $0) }
    } onCancel: {
      Task { @MainActor in
        self.timers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
      }
    }
  }
}
