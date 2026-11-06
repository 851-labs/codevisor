import Foundation

extension WorkspaceSyncModel {
  public func keepTab(workspaceId: UUID, tabId: UUID) {
    guard var workspace = repository.workspace(id: workspaceId),
      let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }),
      workspace.centerTabs[index].isPreview
    else { return }
    workspace.centerTabs[index].isPreview = false
    repository.save(workspace)
  }
}
