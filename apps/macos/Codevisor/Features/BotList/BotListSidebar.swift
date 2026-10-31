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
  @State private var sectionPrompt: SectionPrompt?
  @ClientPreference(SidebarPreferenceKey.collapsedBotSections, default: []) private var collapsedSectionIDs: [String]

  private var conversations: [BotConversation] {
    BotConversationList(environment: environment, store: store).conversations()
  }

  private var sections: CustomSectionStore { environment.botSections }

  private func rows(_ conversations: [BotConversation]) -> [BotSidebarRow] {
    BotSidebarRows.derive(
      BotSidebarRows.State(
        conversations: conversations, sections: sections.sections, membership: sections.membership,
        collapsedSectionIDs: Set(collapsedSectionIDs.compactMap(UUID.init(uuidString:))),
        selectedBotID: selectedBotID))
  }

  private var selectedBotID: UUID? {
    guard case let .bot(_, id) = selection else { return nil }
    return id
  }

  private var canCreateBots: Bool { !environment.bots.botMachines.isEmpty }

  var body: some View {
    scrollingContent
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
          SidebarUpdateFooter(center: environment.updateCenter)
        }
      }
      .modifier(
        SidebarBotsModifier(botEditor: $botEditor, deletingBot: $deletingBot, selection: $selection, store: store)
      )
      .modifier(SectionPromptModifier(prompt: $sectionPrompt, store: sections))
      .sheet(isPresented: $showingAddProject) {
        NewProjectSheet(serverId: environment.defaultComposerServerId) { _ in }
      }
      .modifier(
        SidebarModeSceneActions(
          key: \.botListActions, actions: publishesSceneActions ? actions : nil,
          store: publishesSceneActions ? store : nil, stepHandlerOwner: stepHandlerOwner, step: step)
      )
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
      .contextMenu {
        Button {
          sectionPrompt = .create(moving: nil)
        } label: {
          Label("New Section…", systemImage: "folder.badge.plus")
            .labelStyle(.titleAndIcon)
        }
      }
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
      }
      list
    }
    .padding(.top, 8)
  }

  @ViewBuilder
  private var list: some View {
    let conversations = conversations
    if conversations.isEmpty {
      BotListPlaceholder()
        .containerRelativeFrame(.vertical)
    } else {
      BotConversationRows(
        rows: rows(conversations), sections: sections.sections, selectedBotID: selectedBotID, actions: rowActions)
    }
  }

  private var rowActions: BotSidebarRowActions {
    BotSidebarRowActions(
      select: select,
      edit: { botEditor = .edit($0) },
      delete: { deletingBot = $0 },
      moveBot: { sections.move($0, to: $1) },
      newSection: { sectionPrompt = .create(moving: $0?.id) },
      toggleSection: toggleSection,
      renameSection: { sectionPrompt = .rename($0) },
      deleteSection: { sections.delete($0.id) },
      moveSection: { sections.moveSection($0, toIndex: $1) }
    )
  }

  private func toggleSection(_ id: UUID) {
    let key = id.uuidString
    if collapsedSectionIDs.contains(key) {
      collapsedSectionIDs.removeAll { $0 == key }
    } else {
      collapsedSectionIDs.append(key)
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
    guard let target = BotSidebarRows.step(from: selectedBotID, by: offset, in: rows(conversations)) else { return }
    select(target)
  }
}
