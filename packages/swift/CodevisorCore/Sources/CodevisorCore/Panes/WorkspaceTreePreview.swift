import Foundation

public struct WorkspaceTreePreview {
  private let workspaceId: UUID
  private let sourceTab: WorkspaceTab?
  private let preview: SplitNode

  public init(workspace: Workspace, tree: SplitNode) {
    workspaceId = workspace.id
    sourceTab = workspace.selectedCenterTab
    preview = tree
  }

  public func tree(in workspace: Workspace) -> SplitNode? {
    guard workspace.id == workspaceId, workspace.selectedCenterTab == sourceTab else { return nil }
    return preview
  }
}
