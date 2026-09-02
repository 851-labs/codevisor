import Foundation

@MainActor
final class SessionQuietTurnCancellation {
  private var cancellation: (@MainActor @Sendable () -> Void)?

  init(_ cancellation: @escaping @MainActor @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  func cancel() {
    cancellation?()
    cancellation = nil
  }
}

/// Schedules the work that verifies a provider turn after a quiet interval.
///
/// Production uses `continuous`; tests inject a manually advanced scheduler so
/// timer behavior is deterministic without suspending test tasks on stored
/// continuations.
public struct SessionQuietTurnScheduler: Sendable {
  typealias Operation = @MainActor @Sendable () async -> Void
  typealias Schedule =
    @MainActor @Sendable (
      _ interval: Duration,
      _ operation: @escaping Operation
    ) -> SessionQuietTurnCancellation

  let schedule: Schedule

  init(schedule: @escaping Schedule) {
    self.schedule = schedule
  }

  public static let continuous = Self { interval, operation in
    let task = Task { @MainActor in
      do {
        try await Task.sleep(for: interval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await operation()
    }
    return SessionQuietTurnCancellation {
      task.cancel()
    }
  }
}
