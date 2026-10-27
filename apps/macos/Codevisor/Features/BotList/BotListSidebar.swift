import CodevisorCore
import SwiftUI

struct BotListSidebar: View {
  @Environment(AppEnvironment.self) private var environment
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true
  @State private var botEditor: BotEditorTarget?
  @State private var deletingBot: Bot?
  @State private var stepHandlerOwner = UUID()

  private var conversations: [BotConversation] {
    BotConversationList(environment: environment, store: store).conversations()
  }

  private var selectedBotID: UUID? {
    guard case let .bot(_, id) = selection else { return nil }
    return id
  }

  private var canCreateBots: Bool { !environment.bots.botMachines.isEmpty }

  var body: some View {
    scrollingContent
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
      }
      .modifier(
        SidebarBotsModifier(botEditor: $botEditor, deletingBot: $deletingBot, selection: $selection, store: store)
      )
      .focusedSceneValue(\.botListActions, publishesSceneActions ? actions : nil)
      .task(id: store.map(ObjectIdentifier.init)) {
        guard publishesSceneActions else { return }
        store?.setWorkspaceStepHandler(owner: stepHandlerOwner) { offset in step(offset) }
      }
      .onDisappear {
        if publishesSceneActions { store?.clearWorkspaceStepHandler(owner: stepHandlerOwner) }
      }
  }

  private var scrollingContent: some View {
    ScrollViewReader { proxy in
      ScrollView {
        content
      }
      .scrollContentBackground(.hidden)
      .onChange(of: selectedBotID) { _, id in
        if let id { proxy.scrollTo(id) }
      }
    }
  }

  private var content: some View {
    VStack(spacing: 0) {
      if CodevisorAppVariant.isDevelopment {
        SidebarDevelopmentWorktreeRow()
          .padding(.horizontal, 10)
          .padding(.top, 8)
      }
      BotConversationRows(
        conversations: conversations,
        selectedBotID: selectedBotID,
        onSelect: select,
        onEdit: { botEditor = .edit($0) },
        onDelete: { deletingBot = $0 }
      )
    }
  }

  private var actions: BotListActions {
    BotListActions(newBot: canCreateBots ? newBot : nil, stepBot: step, editBot: { botEditor = .edit($0) })
  }

  private func newBot() {
    botEditor = .create
  }

  private func select(_ bot: Bot) {
    selection = .bot(serverId: bot.serverId, id: bot.id)
  }

  private func step(_ offset: Int) {
    let bots = conversations.map(\.bot)
    guard let current = bots.firstIndex(where: { $0.id == selectedBotID }) else {
      if let first = bots.first { select(first) }
      return
    }

    let target = current + offset
    guard bots.indices.contains(target) else { return }
    select(bots[target])
  }
}
