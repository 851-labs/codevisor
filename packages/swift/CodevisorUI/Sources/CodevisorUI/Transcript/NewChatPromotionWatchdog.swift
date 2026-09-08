import Foundation

/// Bounds the UI handoff after a local send. Server and harness latency never
/// consume this deadline; it starts only when navigation begins.
@MainActor
public final class NewChatPromotionWatchdog {
  public static let timeout: Duration = .seconds(2)
  private let sleep: @Sendable (Duration) async throws -> Void
  private var task: Task<Void, Never>?

  public init(
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.sleep = sleep
  }

  public func start(onTimeout: @escaping @MainActor () -> Void) {
    cancel()
    let sleep = sleep
    task = Task {
      do {
        try await sleep(Self.timeout)
        try Task.checkCancellation()
        onTimeout()
      } catch {
        // A completed or superseded transition cancels its deadline.
      }
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  deinit { task?.cancel() }
}
