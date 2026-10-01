import CodevisorProtocol
import Foundation

/// A live tail of the setup events one subject publishes while the server
/// materializes it (a worktree's `worktree.setup`, a clone's
/// `project.setup` and `project.created`).
///
/// The machine's event socket carries every `session.output` token chunk
/// of every session. Following it unfiltered decoded each chunk and hopped
/// it onto the consumer's actor — usually the main actor — just to discard
/// it, and a busy consumer could overflow the stream's buffer, which ended
/// the tail silently. Here only `kinds` are decoded (`shellEventStream`'s
/// filter), the subject filter runs in this tail's own task, and the
/// consumer receives only its own events.
public enum ServerSetupEventTail {
  public enum Item: Sendable {
    case event(ServerEventEnvelope)
    /// The stream had to restart (the server asked for a snapshot, or its
    /// buffer overflowed), so events published meanwhile were missed. The
    /// tail resumes with live events after this.
    case skipped
  }

  /// Restarts after this many interruptions, then ends: a stream that keeps
  /// failing immediately must not spin.
  static let maximumRestarts = 3

  /// Subscribes before returning, so events published as soon as the
  /// caller starts its request are not missed.
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

  /// The line shown in a setup log where the tail had to restart.
  public static let skippedOutputLine = "… some output was skipped"
}

extension WorktreeSetupEvent {
  public struct LogLine: Equatable, Sendable {
    public let stream: String
    public let line: String
  }

  /// The live log of one worktree's setup, parsed off the caller's actor:
  /// the consumer receives only the lines it shows, plus
  /// `ServerSetupEventTail.skippedOutputLine` where some were missed.
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
