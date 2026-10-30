import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func botChat(_ sessionId: UUID) -> Bot? {
    guard botsEnabled else { return nil }
    return environment.bots.bot(forSession: sessionId, serverId: selectedWorkspace.serverId)
  }

  func chatPaneRole(for descriptor: PaneDescriptorState) -> ChatPaneRole {
    if descriptor.kind == .transcript { return .fullTranscript }
    if descriptor.chatSessionId.flatMap(botChat)?.isConversational == true { return .botConversation }
    return .chat
  }

  func openBotTranscript(_ bot: Bot) {
    guard !isSinglePane else { return }
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: {
      $0.kind == .transcript && $0.ownerChatSessionId == bot.sessionId
    }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return
    }
    guard let botPane = workspace.pane(containingChat: bot.sessionId) else { return }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .transcript, name: "Full Transcript", terminalKey: id.uuidString,
      ownerChatSessionId: bot.sessionId
    )
    guard let inserted = workspace.insertPane(pane, besidePane: botPane.id, destination: .foregroundTab)
    else { return }
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
  }
}
