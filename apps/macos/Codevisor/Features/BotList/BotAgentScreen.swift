import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotAgentScreen: View {
  let chat: ChatSession
  let controller: SessionController
  let surface: TranscriptPresentationSurface
  let focus: TerminalFocusController

  var body: some View {
    ChatScreen(
      controller: controller,
      focus: focus,
      presentationSurface: surface,
      isReadOnly: chat.isArchived
    )
    .environment(\.transcriptTopChromeHeight, BotAgentHeader.height)
    .overlay(alignment: .top) {
      BotAgentHeader(chat: chat)
        .ignoresSafeArea(edges: .top)
    }
    .id(chat.id)
  }
}

private struct BotAgentHeader: View {
  static let height: CGFloat = 44

  let chat: ChatSession

  var body: some View {
    HStack(spacing: 6) {
      HarnessIcon(harnessId: chat.harnessId, fallbackSymbolName: "bubble.and.pencil", size: SidebarRowIcon.size)
        .foregroundStyle(.secondary)
      Text(chat.title.isEmpty ? "Agent" : chat.title)
        .font(.headline)
        .lineLimit(1)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .glassEffect(.regular, in: .capsule)
    .padding(.top, 8)
    .frame(height: Self.height, alignment: .top)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

extension AppEnvironment {
  func openAgentChat(of bot: Bot) -> ChatSession? {
    guard let id = botThreads.openAgent(of: bot),
      let chat = projectList.chat(id, preferring: bot.serverId), !chat.isArchived
    else { return nil }
    return chat
  }

  func hasOpenPage(_ bot: Bot) -> Bool {
    botThreads.openThread(of: bot) != nil || openAgentChat(of: bot) != nil
  }

  func leavesCoveredByBotPage(in workspace: Workspace) -> Set<UUID> {
    guard let bot = bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId), hasOpenPage(bot),
      let conversation = workspace.centerTree.groupId(containingChat: bot.sessionId)
    else { return [] }
    return Set(workspace.centerTree.allGroups.map(\.id)).subtracting([conversation])
  }

  func botShowing(_ chat: ChatSession) -> Bot? {
    var current = chat
    var seen: Set<UUID> = [chat.id]
    while let owner = projectList.parent(of: current), seen.insert(owner.id).inserted {
      if let bot = bots.bot(forSession: owner.id, serverId: owner.serverId) { return bot }
      current = owner
    }
    return nil
  }
}
