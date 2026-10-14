import CodevisorProtocol
import Foundation

public enum ServerSetupEventTail {
  public enum Item: Sendable {
    case event(ServerEventEnvelope)
    case skipped
  }

  static let maximumRestarts = 3

  public static func follow(
    _ client: any CodevisorServerClienting,
    kinds: Set<String>,
    subjectId: String
  ) -> AsyncStream<Item> {
    let subscribe: @Sendable () -> AsyncThrowingStream<ServerEventEnvelope, any Error> = {
      client.shellEventStream(since: ServerSessionTransport.liveOnlyEventCursor, handledKinds: kinds)
    }
    let first = subscribe()
    return AsyncStream { continuation in
      let task = Task {
        var source = first
        var restarts = 0
        while !Task.isCancelled {
          do {
            for try await event in source
            where event.subjectId.caseInsensitiveCompare(subjectId) == .orderedSame {
              continuation.yield(.event(event))
            }
            break
          } catch {
            guard !Task.isCancelled, restarts < maximumRestarts else { break }
            restarts += 1
            continuation.yield(.skipped)
            source = subscribe()
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public static let skippedOutputLine = "… some output was skipped"
}

extension WorktreeSetupEvent {
  public struct LogLine: Equatable, Sendable {
    public let stream: String
    public let line: String
  }

  public static func liveLog(_ client: any CodevisorServerClienting, worktreeId: String) -> AsyncStream<LogLine> {
    let tail = ServerSetupEventTail.follow(client, kinds: ["worktree.setup"], subjectId: worktreeId)
    return AsyncStream { continuation in
      let task = Task {
        for await item in tail {
          switch item {
          case let .event(envelope):
            if case let .log(stream, line) = from(envelope, worktreeId: worktreeId) {
              continuation.yield(LogLine(stream: stream, line: line))
            }
          case .skipped:
            continuation.yield(LogLine(stream: "stderr", line: ServerSetupEventTail.skippedOutputLine))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
