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

  public var phase: SessionSetupPhase {
    let project = kind == "project.setup"
    var phase = SessionSetupPhase(
      id: id,
      activeTitle: project ? "Setting up project" : "Setting up worktree",
      completedTitle: project ? "Set up project" : "Set up worktree",
      failedTitle: project ? "Could not set up project" : "Could not set up worktree",
      startedAt: ISO8601DateFormatter().date(from: createdAt) ?? Date(timeIntervalSince1970: 0))
    phase.logResource = resource
    if state == "completed" { phase.succeed(durationMs: durationMs) }
    if state == "failed" { phase.fail(message: message ?? "Setup failed", durationMs: durationMs) }
    return phase
  }
}
