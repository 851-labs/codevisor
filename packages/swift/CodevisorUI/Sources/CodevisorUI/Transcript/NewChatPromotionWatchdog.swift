import Foundation

@MainActor
public final class NewChatPromotionWatchdog {
  public static let timeout: Duration = .seconds(3)
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
      }
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  deinit { task?.cancel() }
}
