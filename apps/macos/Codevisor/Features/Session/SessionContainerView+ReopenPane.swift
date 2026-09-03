import CodevisorCore
import SwiftUI

// MARK: - Reopen closed pane (⌘⇧T)

extension SessionContainerView {
  /// Records a closing center pane so ⌘⇧T can bring it back. Skipped for
  /// what cannot meaningfully return: the New Tab placeholder, an unsent
  /// draft (its composer state is discarded on close), and agent-owned
  /// terminals (they belong to their background task, not the user).
  func rememberClosedPane(_ descriptor: PaneDescriptorState, leafId: UUID) {
    guard descriptor.kind != .newTab, !descriptor.attachOnly else { return }
    if descriptor.kind == .chat, descriptor.chatSessionId == nil { return }
    // The hook fires before the tab is pruned, so its position is still
    // readable here.
    let workspace = store.workspace(for: session, project: project)
    guard
      let tabIndex = workspace.centerTabs.firstIndex(where: { $0.root.group(id: leafId) != nil })
    else { return }
    store.recordClosedPane(
      ClosedPaneRecord(
        descriptor: descriptor,
        tabId: workspace.centerTabs[tabIndex].id,
        tabIndex: tabIndex
      ),
      workspaceId: workspace.id
    )
  }

  /// Browser semantics: the most recently closed pane comes back as a new
  /// top tab, placed right after the tab it came from when that tab still
  /// exists, else at its old index. A chat returns unarchived; a terminal
  /// returns as a fresh shell under its old name (closing deleted its
  /// server shell); a plugin pane reloads. Entries whose chat no longer
  /// exists are skipped in favor of the next one.
  func reopenClosedPane() {
    var workspace = store.workspace(for: session, project: project)
    while let record = store.popClosedPane(workspaceId: workspace.id) {
      // A chat reopened meanwhile (from the archive) already has a pane:
      // go to it rather than open a duplicate.
      if record.descriptor.kind == .chat,
        let chatId = record.descriptor.chatSessionId,
        let existingTabId = workspace.tabId(containingChat: chatId)
      {
        selectCenterTab(existingTabId)
        if chatId != session.id { onFocusedChatChanged?(chatId) }
        return
      }
      guard let pane = restoredDescriptor(for: record.descriptor) else { continue }

      if let current = workspace.selectedCenterTab {
        for leaf in current.root.allGroups {
          configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
        }
      }
      let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id, isVisible: true)
      let tab = WorkspaceTab(root: .leaf(state))
      let index =
        workspace.centerTabs.firstIndex(where: { $0.id == record.tabId }).map { $0 + 1 }
        ?? min(record.tabIndex, workspace.centerTabs.count)
      workspace.centerTabs.insert(tab, at: index)
      workspace.selectedCenterTabId = tab.id
      environment.workspaces.save(workspace)
      workspaceRevision += 1
      liveCenterTree = tab.root
      activateLeaf(tab.activeLeafId)
      publishPane(pane, workspaceId: workspace.id)
      let model = configuredCenterModel(leafId: tab.activeLeafId)
      model.selectedPane?.visibilityChanged(true)
      if pane.kind == .chat, let chatId = pane.chatSessionId, chatId != session.id {
        // The sidebar follows the chat; its routing task then selects the
        // tab and focuses the composer.
        onFocusedChatChanged?(chatId)
      } else {
        DispatchQueue.main.async { model.focusSelectedPane() }
      }
      return
    }
  }

  /// A fresh descriptor for the returning pane. New identity on purpose:
  /// the closed pane's id was already published as deleted, and reusing
  /// it would race that deletion in the sync queue.
  private func restoredDescriptor(for closed: PaneDescriptorState) -> PaneDescriptorState? {
    let paneId = UUID()
    switch closed.kind {
    case .chat:
      guard let chatId = closed.chatSessionId,
        let chat = environment.projectList.sessions.first(where: {
          $0.serverId == session.serverId && $0.id == chatId
        })
      else { return nil }
      if chat.isArchived {
        environment.projectList.unarchiveSession(chat)
      }
      return PaneDescriptorState(
        id: paneId, kind: .chat, name: closed.name,
        terminalKey: paneId.uuidString, chatSessionId: chatId
      )
    case .terminal:
      return PaneDescriptorState(
        id: paneId, kind: .terminal, name: closed.name,
        terminalKey: "\(session.id.uuidString):\(paneId.uuidString)"
      )
    case .plugin:
      return PaneDescriptorState(
        id: paneId, kind: .plugin, name: closed.name,
        terminalKey: paneId.uuidString,
        pluginId: closed.pluginId, pluginPaneType: closed.pluginPaneType
      )
    case .newTab:
      return nil
    }
  }
}
