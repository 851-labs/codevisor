import Foundation

enum WorktreeSetupSignal: Equatable, Sendable {
  case created(ServerWorktree)
  case failed(String)
  case recheck

  static let eventKinds: Set<String> = ["worktree.setup", "worktree.created"]

  static func events(
    _ client: any CodevisorServerClienting, worktreeId: String
  ) -> AsyncStream<ServerSetupEventTail.Item> {
    ServerSetupEventTail.follow(client, kinds: eventKinds, subjectId: worktreeId)
  }

  static func stream(
    from tail: AsyncStream<ServerSetupEventTail.Item>,
    worktreeId: String,
    recheckEvery interval: Duration,
    clock: any Clock<Duration>
  ) -> AsyncStream<WorktreeSetupSignal> {
    AsyncStream { continuation in
      let events = Task {
        for await item in tail {
          if let signal = signal(from: item, worktreeId: worktreeId) { continuation.yield(signal) }
        }
      }
      let rechecks = Task {
        while (try? await clock.sleep(for: interval)) != nil {
          continuation.yield(.recheck)
        }
      }
      continuation.onTermination = { _ in
        events.cancel()
        rechecks.cancel()
      }
    }
  }

  static func signal(from item: ServerSetupEventTail.Item, worktreeId: String) -> WorktreeSetupSignal? {
    switch item {
    case .skipped: .recheck
    case let .event(envelope): signal(from: envelope, worktreeId: worktreeId)
    }
  }

  private static func signal(from envelope: ServerEventEnvelope, worktreeId: String) -> WorktreeSetupSignal? {
    if envelope.kind == "worktree.created" { return (try? envelope.worktreeRecord()).map(Self.created) }
    guard case let .failed(message, _) = WorktreeSetupEvent.from(envelope, worktreeId: worktreeId) else { return nil }
    return .failed(message)
  }
}

extension ServerEventEnvelope {
  func worktreeRecord() throws -> ServerWorktree {
    try JSONDecoder().decode(ServerWorktree.self, from: JSONEncoder().encode(payload))
  }
}
