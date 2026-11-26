import CodevisorCore
import SwiftUI

extension SessionContainerView {
  func botChat(_ sessionId: UUID) -> Bot? {
    environment.bots.bot(forSession: sessionId, serverId: selectedWorkspace.serverId)
  }

  var botPage: BotPage? {
    environment.botPages.page(in: selectedWorkspace)
  }

  var agentPage: ChatSession? {
    botPage?.agent
  }

  func presentedAgent(in pane: PaneDescriptorState?) -> ChatSession? {
    guard let chatId = pane?.chatSessionId, botChat(chatId)?.workspaceId == selectedWorkspace.id else { return nil }

    return agentPage
  }

  func presentedChatId(in pane: PaneDescriptorState?) -> UUID? {
    presentedAgent(in: pane)?.id ?? pane?.chatSessionId
  }

  func chatPaneRole(for descriptor: PaneDescriptorState) -> ChatPaneRole {
    if descriptor.kind == .transcript { return .fullTranscript }
    if descriptor.chatSessionId.flatMap(botChat) != nil { return .botConversation }
    return .chat
  }

  func openBotTranscript(_ bot: Bot) {
    guard !isTabless else { return }
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
