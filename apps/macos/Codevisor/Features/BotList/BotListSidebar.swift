import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotListSidebar: View {
  @Environment(AppEnvironment.self) private var environment
  @Binding var selection: SidebarSelection?
  var store: SessionStore? = nil
  var publishesSceneActions = true
  @State private var botEditor: BotEditorTarget?
  @State private var showingAddProject = false
  @State private var deletingBot: Bot?
  @State private var stepHandlerOwner = UUID()

  private var rows: [BotSidebarRow] {
    let conversations = BotConversationList(environment: environment, store: store).conversations()
    return BotSidebarRows.derive(BotSidebarRows.State(conversations: conversations))
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
      .sheet(isPresented: $showingAddProject) {
        NewProjectSheet(serverId: environment.defaultComposerServerId) { _ in }
      }
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
        rows: rows,
        selectedBotID: selectedBotID,
        onSelect: select,
        onEdit: { botEditor = .edit($0) },
        onDelete: { deletingBot = $0 }
      )
    }
  }

  private var actions: BotListActions {
    BotListActions(
      newBot: canCreateBots ? newBot : nil, newProject: { showingAddProject = true }, stepBot: step,
      editBot: { botEditor = .edit($0) })
  }

  private func newBot() {
    botEditor = .create
  }

  private func select(_ bot: Bot) {
    selection = .bot(serverId: bot.serverId, id: bot.id)
  }

  private func step(_ offset: Int) {
    guard let target = BotSidebarRows.step(from: selectedBotID, by: offset, in: rows) else { return }
    select(target)
  }
}
