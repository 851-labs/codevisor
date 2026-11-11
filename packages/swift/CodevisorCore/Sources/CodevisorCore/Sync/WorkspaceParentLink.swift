import Foundation

public struct WorkspaceParentLink: Equatable, Sendable {
  public let workspaceId: UUID
  public let linkedAt: Date
  public let isQuiet: Bool

  public init(workspaceId: UUID, linkedAt: Date, isQuiet: Bool) {
    self.workspaceId = workspaceId
    self.linkedAt = linkedAt
    self.isQuiet = isQuiet
  }
}
