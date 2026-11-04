import CodevisorCore
import Foundation

public struct QuietChildren {
  private let tree: SidebarWorkspaceTree
  private let collapsedGroupIDs: Set<String>

  public init(tree: SidebarWorkspaceTree, disclosure: SidebarChildDisclosure) {
    self.tree = tree
    collapsedGroupIDs = disclosure.collapsedGroupIDs(in: tree)
  }

  public func contains(_ workspaceId: UUID) -> Bool {
    guard let parent = tree.parent(of: workspaceId) else { return false }
    return collapsedGroupIDs.contains(SidebarRows.childrenGroupID(parent)) || contains(parent)
  }

  public func announces(
    _ session: SessionAttentionFocus, workspaceId: UUID?, openSessions: Set<SessionAttentionFocus>
  ) -> Bool {
    guard let workspaceId, contains(workspaceId) else { return true }
    return openSessions.contains(session)
  }
}
