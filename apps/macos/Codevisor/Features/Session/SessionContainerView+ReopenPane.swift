import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func rememberClosedPane(_ descriptor: PaneDescriptorState, leafId: UUID) {
    guard descriptor.kind != .newTab else { return }
    if descriptor.kind == .chat, descriptor.chatSessionId == nil { return }
    let workspace = selectedWorkspace
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

  func reopenClosedPane() {
    var workspace = selectedWorkspace
    while let record = store.popClosedPane(workspaceId: workspace.id) {
      if record.descriptor.kind == .chat,
        let chatId = record.descriptor.chatSessionId,
        workspace.tabId(containingChat: chatId) != nil
      {
        store.selectDestination(.chat(chatId), in: workspace.id)
        if chatId != session?.id { onFocusedChatChanged?(chatId) }
        return
      }
      guard let pane = restoredDescriptor(for: record.descriptor) else { continue }

      let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
      let tab = WorkspaceTab(root: .leaf(state))
      let index =
        workspace.centerTabs.firstIndex(where: { $0.id == record.tabId }).map { $0 + 1 }
        ?? min(record.tabIndex, workspace.centerTabs.count)
      workspace.centerTabs.insert(tab, at: index)
      environment.workspaces.save(workspace)
      store.selectDestination(.tab(tab.id), in: workspace.id)
      publishPane(pane, workspaceId: workspace.id)
      if pane.kind == .chat, let chatId = pane.chatSessionId, chatId != session?.id {
        onFocusedChatChanged?(chatId)
      }
      focusSelectedCenterPane()
      return
    }
  }

  private func restoredDescriptor(for closed: PaneDescriptorState) -> PaneDescriptorState? {
    let paneId = UUID()
    switch closed.kind {
    case .chat:
      guard let chatId = closed.chatSessionId,
        environment.projectList.session(chatId, serverId: selectedWorkspace.serverId) != nil
      else { return nil }
      return PaneDescriptorState(
        id: paneId, kind: .chat, name: closed.name,
        terminalKey: paneId.uuidString, chatSessionId: chatId
      )
    case .terminal:
      guard let session else { return nil }
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
    case .browser:
      return PaneDescriptorState(
        id: paneId, kind: .browser, name: closed.name,
        terminalKey: paneId.uuidString, browserURL: closed.browserURL, browserFavicon: closed.browserFavicon)
    case .screenSharing:
      return PaneDescriptorState(
        id: paneId, kind: .screenSharing, name: closed.name,
        terminalKey: paneId.uuidString, screenSharing: closed.screenSharing)
    case .review:
      return PaneDescriptorState(
        id: paneId, kind: .review, name: closed.name,
        terminalKey: paneId.uuidString, review: closed.review)
    case .simulator:
      return PaneDescriptorState(
        id: paneId, kind: .simulator, name: closed.name,
        terminalKey: paneId.uuidString, simulator: closed.simulator)
    case .document:
      return PaneDescriptorState(
        id: paneId, kind: .document, name: closed.name,
        terminalKey: paneId.uuidString, documentPath: closed.documentPath
      )
    case .subagent:
      guard let owner = closed.ownerChatSessionId, selectedWorkspace.pane(containingChat: owner) != nil
      else { return nil }
      return PaneDescriptorState(
        id: paneId, kind: .subagent, name: closed.name, terminalKey: paneId.uuidString,
        ownerChatSessionId: closed.ownerChatSessionId, subagentToolCallId: closed.subagentToolCallId)
    case .transcript:
      guard let owner = closed.ownerChatSessionId, selectedWorkspace.pane(containingChat: owner) != nil
      else { return nil }
      return PaneDescriptorState(
        id: paneId, kind: .transcript, name: closed.name, terminalKey: paneId.uuidString,
        ownerChatSessionId: owner)
    case .newTab:
      return nil
    }
  }
}
