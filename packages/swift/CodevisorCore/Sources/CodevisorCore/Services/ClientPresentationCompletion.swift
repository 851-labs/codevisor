import Foundation

/// Wait for SwiftUI's dismissal callback before accepting the next command.
/// A returned logical nil alone does not mean UIKit has released the sheet.
@MainActor
public final class ClientPresentationCompletion {
  private let timeout: @Sendable () async throws -> Void

  public init(timeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(8)) }) {
    self.timeout = timeout
  }
  private var pending: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

  public func dismiss(_ name: String, action: () -> Void) async throws {
    try Task.checkCancellation()
    let timeout = self.timeout
    let id = UUID()
    let stream = AsyncStream<Void> { continuation in
      pending[name, default: [:]][id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.pending[name]?[id] = nil }
      }
    }
    action()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in stream { return }
        try Task.checkCancellation()
      }
      group.addTask {
        try await timeout()
        throw ClientControlError("Presentation is still closing. Read context before retrying.")
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  public func complete(_ name: String) {
    let continuations = pending.removeValue(forKey: name)?.values
    for continuation in continuations ?? [:].values {
      continuation.yield(())
      continuation.finish()
    }
  }
}
