import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotListSidebar: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.isActiveSidebarMode) private var isActiveSidebarMode
  @Binding var selection: SidebarSelection?
  @Binding var botEditor: BotEditorTarget?
  var store: SessionStore? = nil
  var publishesSceneActions = true
  @State private var showingAddProject = false
  @State private var deletingBot: Bot?
  @State private var stepHandlerOwner = UUID()
  @State private var sectionPrompt: SectionPrompt?
  @ClientPreference(SidebarPreferenceKey.collapsedBotSections, default: []) private var collapsedSectionIDs: [String]
  @ClientPreference(SidebarPreferenceKey.botArchivedExpanded, default: false) private var archivedExpanded

  private var conversations: [BotConversation] {
    BotConversationList(environment: environment, store: store).conversations()
  }

  private var sections: CustomSectionStore { environment.botSections }

  private func rows(_ conversations: [BotConversation]) -> [BotSidebarRow] {
    BotSidebarRows.derive(
      BotSidebarRows.State(
        conversations: conversations, sections: sections.sections, membership: sections.membership,
        collapsedSectionIDs: Set(collapsedSectionIDs.compactMap(UUID.init(uuidString:))),
        isArchivedExpanded: archivedExpanded, selectedBotID: selectedBotID))
  }

  private var selectedBot: Bot? {
    guard case let .bot(serverId, id) = selection else { return nil }
    return environment.bots.bot(serverId: serverId, id: id)
  }

  private var selectedBotID: UUID? {
    guard case let .bot(_, id) = selection else { return nil }
    return id
  }

  var body: some View {
    vibrantList
      .modifier(
        SidebarBotsModifier(deletingBot: $deletingBot, selection: $selection)
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

  private var vibrantList: some View {
    SidebarVibrancyHost {
      scrollingContent
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            SidebarSyncFooter(indicator: environment.navigationSyncIndicator)
            SidebarUpdateFooter(center: environment.updateCenter)
          }
        }
        .environment(environment)
        .environment(\.isActiveSidebarMode, isActiveSidebarMode)
    }
    .ignoresSafeArea(.container, edges: .top)
  }

  private var scrollingContent: some View {
    BotListScrollView(
      selectedBotID: selectedBotID, isSelectedBotArchived: selectedBot?.isArchived == true,
      newSection: { sectionPrompt = .create(moving: nil) }
    ) {
      content
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
      canFork: { environment.bots.supportsFork(on: $0.serverId) },
      fork: { botEditor = .fork($0) },
      canArchive: { environment.bots.supportsArchive(on: $0.serverId) },
      archive: archive,
      unarchive: { setArchived($0, false) },
      delete: { deletingBot = $0 },
      moveBot: { sections.move($0, to: $1) },
      placeBot: { environment.moveBot($0, to: $1, among: conversations) },
      newSection: { sectionPrompt = .create(moving: $0?.id) },
      toggleSection: toggleSection,
      toggleArchived: { archivedExpanded.toggle() },
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
      newProject: { showingAddProject = true }, stepBot: step,
      archiveBot: archivableSelectedBot == nil ? nil : archiveSelectedBot)
  }

  private func archiveSelectedBot() {
    if let bot = archivableSelectedBot { archive(bot) }
  }

  private var archivableSelectedBot: Bot? {
    guard let bot = selectedBot, !bot.isArchived, environment.bots.supportsArchive(on: bot.serverId) else { return nil }
    return bot
  }

  private func archive(_ bot: Bot) {
    if selectedBotID == bot.id {
      selection =
        BotSidebarRows.replacement(forArchiving: bot.id, in: rows(conversations))
        .map { .bot(serverId: $0.serverId, id: $0.id) } ?? .newChat(nil)
    }
    setArchived(bot, true)
  }

  private func setArchived(_ bot: Bot, _ isArchived: Bool) {
    Task {
      do {
        try await environment.bots.setArchived(bot, isArchived)
      } catch {
        ErrorReporter.shared.report(isArchived ? "Couldn't archive bot" : "Couldn't unarchive bot", error: error)
      }
    }
  }

  private func select(_ bot: Bot) {
    selection = .bot(serverId: bot.serverId, id: bot.id)
  }

  private func step(_ offset: Int) {
    guard let target = BotSidebarRows.step(from: selectedBotID, by: offset, in: rows(conversations)) else { return }
    select(target)
  }
}
