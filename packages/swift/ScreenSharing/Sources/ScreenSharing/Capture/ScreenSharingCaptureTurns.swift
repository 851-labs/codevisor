@MainActor
final class ScreenSharingCaptureTurns {
  private var tail: Task<Void, Never>?
  private(set) var queued = 0

  func run(_ work: @escaping @MainActor () async throws -> Void) async throws {
    let previous = tail
    queued += 1
    let turn = Task { @MainActor [self] in
      defer { queued -= 1 }
      await previous?.value
      try await work()
    }
    tail = Task { _ = try? await turn.value }
    try await withTaskCancellationHandler {
      try await turn.value
    } onCancel: {
      turn.cancel()
    }
  }
}
