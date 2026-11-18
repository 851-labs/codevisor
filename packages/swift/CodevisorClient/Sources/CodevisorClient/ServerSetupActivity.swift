import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerSetupActivity: Decodable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var state: String
  public var createdAt: String
  public var message: String?
  public var durationMs: Double?
  public var resource: ToolDetailResource?

  public var afterItemId: String?
  public var lines: [String]?

  public var phase: SessionSetupPhase {
    let titles = Self.titles(for: kind)
    var phase = SessionSetupPhase(
      id: id,
      activeTitle: titles.active,
      completedTitle: titles.completed,
      failedTitle: titles.failed,
      startedAt: ISO8601DateFormatter().date(from: createdAt) ?? Self.fractionalDate(createdAt)
        ?? Date(timeIntervalSince1970: 0))
    phase.logResource = resource
    phase.followsItemId = afterItemId.flatMap(UUID.init(uuidString:))
    for line in lines ?? [] { phase.appendLog(stream: "stdout", line: line) }
    if state == "completed" { phase.succeed(durationMs: durationMs) }
    if state == "failed" { phase.fail(message: message ?? "Setup failed", durationMs: durationMs) }
    return phase
  }

  private static func titles(for kind: String) -> (active: String, completed: String, failed: String) {
    switch kind {
    case "project.setup": ("Setting up project", "Set up project", "Could not set up project")
    case "sandbox.restore": ("Restoring sandbox", "Restored sandbox", "Could not restore sandbox")
    default: ("Setting up worktree", "Set up worktree", "Could not set up worktree")
    }
  }

  private static func fractionalDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}
