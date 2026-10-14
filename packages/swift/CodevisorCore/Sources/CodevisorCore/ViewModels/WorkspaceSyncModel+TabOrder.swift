import Foundation

extension WorkspaceSyncModel {
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

  public func moveTab(_ tabId: UUID, before successorId: UUID?, inWorkspace workspaceId: UUID) {
    guard let workspace = repository.workspace(id: workspaceId) else { return }
    let others = workspace.centerTabs.map(\.id).filter { $0 != tabId }
    let index = successorId.flatMap { others.firstIndex(of: $0) } ?? others.count
    moveTab(tabId, toIndex: index, inWorkspace: workspaceId)
  }
}
