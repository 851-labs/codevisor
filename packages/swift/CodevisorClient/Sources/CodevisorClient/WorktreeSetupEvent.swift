import ACPKit
import CodevisorProtocol
import Foundation

/// A decoded `worktree.setup` event envelope: progress the server publishes
/// while it materializes a worktree (subjectId = the worktree id supplied by
/// the client at creation time).
public enum WorktreeSetupEvent: Equatable, Sendable {
  case started
  case log(stream: String, line: String)
  case completed(durationMs: Double?)
  case failed(message: String, durationMs: Double?)

  public static func from(_ envelope: ServerEventEnvelope, worktreeId: String) -> WorktreeSetupEvent? {
    guard envelope.kind == "worktree.setup",
      envelope.subjectId.caseInsensitiveCompare(worktreeId) == .orderedSame,
      let state = envelope.payload["state"]?.stringValue
    else {
      return nil
    }
    switch state {
    case "started":
      return .started
    case "log":
      guard let line = envelope.payload["line"]?.stringValue else { return nil }
      return .log(stream: envelope.payload["stream"]?.stringValue ?? "stdout", line: line)
    case "completed":
      return .completed(durationMs: envelope.payload["durationMs"]?.doubleValue)
    case "failed":
      return .failed(
        message: envelope.payload["message"]?.stringValue ?? "Worktree setup failed.",
        durationMs: envelope.payload["durationMs"]?.doubleValue
      )
    default:
      return nil
    }
  }
}
