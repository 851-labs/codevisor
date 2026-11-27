@MainActor
final class ScreenSharingCaptureTurns {
  private var tail: Task<Void, Never>?

  func run<Value: Sendable>(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let previous = tail
    let turn = Task { @MainActor () async throws -> Value in
      await previous?.value
      return try await work()
    }
    tail = Task { _ = try? await turn.value }
    return try await withTaskCancellationHandler {
      try await turn.value
    } onCancel: {
      turn.cancel()
    }
  }
}
