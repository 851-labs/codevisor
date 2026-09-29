import Foundation

extension WorkspaceSyncModel {
  /// Moves a tab to `index` in its workspace. The order is shared: every
  /// device shows the tab in its new place (splits stay per device).
  public func moveTab(_ tabId: UUID, toIndex index: Int, inWorkspace workspaceId: UUID) {
    guard var workspace = repository.workspace(id: workspaceId),
      let from = workspace.centerTabs.firstIndex(where: { $0.id == tabId })
    else { return }
    let tab = workspace.centerTabs.remove(at: from)
    let target = min(max(0, index), workspace.centerTabs.count)
    guard target != from else { return }
    workspace.centerTabs.insert(tab, at: target)
    repository.save(workspace)
  }

  /// Moves a tab in front of `successorId`, or to the end when it is nil.
  /// Sidebars drop relative to a neighbour rather than an index: they hide
  /// some tabs, so their row positions don't match the tab list.
  public func moveTab(_ tabId: UUID, before successorId: UUID?, inWorkspace workspaceId: UUID) {
    guard let workspace = repository.workspace(id: workspaceId) else { return }
    let others = workspace.centerTabs.map(\.id).filter { $0 != tabId }
    let index = successorId.flatMap { others.firstIndex(of: $0) } ?? others.count
    moveTab(tabId, toIndex: index, inWorkspace: workspaceId)
  }
}
