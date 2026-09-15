import Foundation

extension WorkspaceSyncModel {
  /// Both sidebars and the Mac title editor route chat renames through the
  /// shared session record. Non-chat layout labels retain their local meaning.
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
      // Old local aliases must not mask this or another device's chat rename.
      if workspace.centerTabs[index].customTitle != nil {
        workspace.centerTabs[index].customTitle = nil
        repository.save(workspace)
        noteLocalMutation()
      }
      return projectList.renameSession(chat, to: trimmed, errorReporter: errorReporter)
    }
    let normalized = trimmed.isEmpty ? nil : trimmed
    guard workspace.centerTabs[index].customTitle != normalized else { return nil }
    workspace.centerTabs[index].customTitle = normalized
    repository.save(workspace)
    noteLocalMutation()
    return nil
  }
}
