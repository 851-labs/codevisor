import Foundation

public struct WorkspaceParentLink: Equatable, Sendable {
  public let workspaceId: UUID
  public let linkedAt: Date
  public let isAgentMade: Bool

  public init(workspaceId: UUID, linkedAt: Date, isAgentMade: Bool) {
    self.workspaceId = workspaceId
    self.linkedAt = linkedAt
    self.isAgentMade = isAgentMade
  }
}
