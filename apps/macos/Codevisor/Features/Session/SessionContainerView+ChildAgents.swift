import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func openChildAgent(_ request: ChildAgentSplitRequest) {
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: {
      $0.kind == .childAgent && $0.chatSessionId == request.chatSessionId
    }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return
    }
    guard let besidePane = childAgentAnchor(in: workspace) else { return }

    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .childAgent, name: request.name, terminalKey: id.uuidString, chatSessionId: request.chatSessionId)
    guard let inserted = workspace.insertPane(pane, besidePane: besidePane, destination: .split(.trailing))
    else { return }
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
  }

  func botAgentChats(replacing placeholderId: UUID) -> NewPaneAgentChats? {
    let workspace = selectedWorkspace
    guard isTabless, environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) != nil
    else { return nil }

    let agents = environment.navigationStore.workspaceEntries.sidebar.filter { $0.parentWorkspaceId == workspace.id }
    return NewPaneAgentChats(chats: agents.compactMap(agentChat)) { chat in
      openAgentChat(chat, replacing: placeholderId)
    }
  }

  private func agentChat(_ agent: WorkspaceSidebarItem) -> NewPaneAgentChats.Chat? {
    guard let sessionId = agent.routingChatIds.first, let workspace = environment.workspaces.workspace(id: agent.id)
    else { return nil }
    return NewPaneAgentChats.Chat(id: sessionId, name: workspace.name)
  }

  private func openAgentChat(_ chat: NewPaneAgentChats.Chat, replacing placeholderId: UUID) {
    var workspace = selectedWorkspace
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .childAgent, name: chat.name, terminalKey: id.uuidString, chatSessionId: chat.id)
    guard let replaced = workspace.replacePane(id: placeholderId, with: pane) else { return }

    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.leaf(replaced.leafId), in: workspace.id)
    focusSelectedCenterPane()
  }

  private func childAgentAnchor(in workspace: Workspace) -> UUID? {
    guard let tab = workspace.selectedCenterTab, let leafId = tab.resolvedActiveLeafId(preferred: activeLeafId)
    else { return workspace.allPanes.first?.id }
    return tab.root.group(id: leafId)?.selectedPane?.id
  }
}
