import CodevisorCore
import Foundation

public struct QuietChildren {
  private let quietIDs: Set<UUID>

  public init(_ items: [WorkspaceSidebarItem]) {
    quietIDs = Set(items.filter(Self.isQuiet).map(\.id))
  }

  public static func isQuiet(_ item: WorkspaceSidebarItem) -> Bool {
    item.parent?.isAgentMade == true
  }

  public func contains(_ workspaceId: UUID) -> Bool {
    quietIDs.contains(workspaceId)
  }

  public func announces(workspaceId: UUID?) -> Bool {
    guard let workspaceId else { return true }
    return !contains(workspaceId)
  }
}
