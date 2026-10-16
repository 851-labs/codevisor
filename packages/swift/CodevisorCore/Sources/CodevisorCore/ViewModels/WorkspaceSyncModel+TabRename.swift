import Foundation

extension WorkspaceSyncModel {
  @discardableResult
  public func renameTab(
    workspaceId: UUID, tabId: UUID, chatSessionId: UUID? = nil, to title: String,
    errorReporter: ErrorReporter = .shared
  ) -> Task<Void, Never>? {
    guard var workspace = repository.workspace(id: workspaceId),
      let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId })
    else { return nil }
    let tab = workspace.centerTabs[index]
    let pane = tab.root.group(id: tab.activeLeafId)?.selectedPane
    let chatId = chatSessionId ?? (pane?.kind == .chat ? pane?.chatSessionId : nil)
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if let chatId {
      guard !trimmed.isEmpty, tab.root.groupId(containingChat: chatId) != nil,
        let chat = projectList.sessions.first(where: { $0.serverId == workspace.serverId && $0.id == chatId })
      else { return nil }
      if workspace.centerTabs[index].customTitle != nil {
        workspace.centerTabs[index].customTitle = nil
        repository.save(workspace)
      }
      return projectList.renameSession(chat, to: trimmed, errorReporter: errorReporter)
    }
    let normalized = trimmed.isEmpty ? nil : trimmed
    guard tab.customTitle != normalized else { return nil }
    if tab.customTitle == nil, normalized == pane?.displayName { return nil }
    workspace.centerTabs[index].customTitle = normalized
    repository.save(workspace)
    return nil
  }

  public func keepTab(workspaceId: UUID, tabId: UUID) {
    guard var workspace = repository.workspace(id: workspaceId),
      let index = workspace.centerTabs.firstIndex(where: { $0.id == tabId }),
      workspace.centerTabs[index].isPreview
    else { return }
    workspace.centerTabs[index].isPreview = false
    repository.save(workspace)
  }
}
