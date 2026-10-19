import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  static let botsFoldID = "bots"

  var canCreateBots: Bool {
    botsEnabled && !environment.bots.botMachines.isEmpty
  }

  var selectedBotID: UUID? {
    if case let .bot(_, id) = selection { return id }
    return nil
  }

  @ViewBuilder
  var botsSection: some View {
    let entries = botEntries
    if botsEnabled, canCreateBots || !entries.isEmpty {
      SidebarSectionHeader(
        title: "Bots",
        isExpanded: botsExpanded,
        onToggle: { fold(Self.botsFoldID) { botsExpanded.toggle() } },
        add: SidebarSectionHeader.Add(help: "New Bot") { botEditor = .create }
      )
      let isFolding = folds.isFolding(Self.botsFoldID)
      let releasing =
        isFolding || botsExpanded
        ? [] : Set(entries.filter { !keepsSelection($0) && isReleasing($0) }.map(\.id))
      let rows =
        isFolding || botsExpanded
        ? entries : entries.filter { keepsSelection($0) || releasing.contains($0.id) }
      SidebarFoldingList(shows: botsExpanded, isReleasing: !releasing.isEmpty) { progress in
        ForEach(rows) { entry in
          VStack(alignment: .leading, spacing: 1) {
            botRow(entry.bot, hasChildren: !entry.children.isEmpty)
            if !entry.children.isEmpty {
              botChildList(entry)
                .padding(.leading, Self.groupIndent)
            }
          }
          .sidebarFoldingRow(
            releasing.contains(entry.id) ? .releasing : isFolding && !keepsSelection(entry) ? .folding : .kept,
            progress: progress, shows: botsExpanded)
        }
        if entries.isEmpty, botsExpanded || isFolding {
          SidebarActionRow(
            title: "New bot",
            systemImage: "plus",
            isSelected: false,
            isHoverEnabled: !isReordering,
            titleStyle: .secondary
          ) {
            botEditor = .create
          }
          .sidebarFoldingRow(isFolding, progress: progress, shows: botsExpanded)
        }
      }
    }
  }

  var botEntries: [BotSidebarEntry] {
    botsEnabled ? environment.botSidebarEntries : []
  }

  var botNestedWorkspaceIDs: Set<UUID> {
    Set(botEntries.flatMap(\.workspaceIDs))
  }

  var visibleBotEntries: [BotSidebarEntry] {
    botEntries.filter { botsExpanded || keepsSelection($0) }
  }

  func visibleBotChildren(_ entry: BotSidebarEntry) -> [WorkspaceSidebarItem] {
    visible(entry.children, showing: showsBotChildren(entry.bot))
  }

  func isBotSelected(_ bot: Bot) -> Bool {
    bot.id == selectedBotID || bot.workspaceId == selectedWorkspaceID
  }

  static func botGroupID(_ bot: Bot) -> String { "bot:\(bot.serverId)|\(bot.id.uuidString)" }

  func botChildren(containing id: UUID) -> [WorkspaceSidebarItem]? {
    environment.navigationStore.workspaceEntries.botChildren.values.first { $0.contains { $0.id == id } }
  }

  private func keepsSelection(_ entry: BotSidebarEntry) -> Bool {
    isBotSelected(entry.bot) || entry.children.contains { $0.id == selectedWorkspaceID }
  }

  private func isReleasing(_ entry: BotSidebarEntry) -> Bool {
    ([entry.bot.id, entry.bot.workspaceId] + entry.children.map(\.id)).contains(where: folds.isReleasing)
  }

  private func showsBotChildren(_ bot: Bot) -> Bool {
    botsExpanded && !collapsedGroupIDs.contains(Self.botGroupID(bot))
  }

  private func botChildList(_ entry: BotSidebarEntry) -> some View {
    let isExpanded = showsBotChildren(entry.bot)
    guard folds.isFolding(Self.botGroupID(entry.bot)) || folds.isFolding(Self.botsFoldID) else {
      let rows = withReleasedRows(visibleBotChildren(entry), from: entry.children)
      return workspaceList(rows.items, folding: [], releasing: rows.releasing, shows: isExpanded)
    }
    let folding = Set(entry.children.map(\.id)).subtracting([selectedWorkspaceID].compactMap { $0 })
    return workspaceList(entry.children, folding: folding, releasing: [], shows: isExpanded)
  }

  private func toggleBotGroup(_ groupID: String) {
    fold(groupID) {
      if collapsedGroupIDs.contains(groupID) {
        collapsedGroupIDs.removeAll { $0 == groupID }
      } else {
        collapsedGroupIDs.append(groupID)
      }
    }
  }

  private func botRow(_ bot: Bot, hasChildren: Bool) -> some View {
    let groupID = Self.botGroupID(bot)
    return SidebarBotRow(
      title: bot.name,
      icon: SidebarBotIcon(bot: bot, store: store),
      isSelected: isBotSelected(bot),
      isHoverEnabled: !isReordering,
      isExpanded: hasChildren && botsExpanded ? !collapsedGroupIDs.contains(groupID) : nil,
      onSelect: { selection = .bot(serverId: bot.serverId, id: bot.id) },
      onToggle: { toggleBotGroup(groupID) }
    )
    .contextMenu {
      Button("Edit Bot…", systemImage: "pencil") { botEditor = .edit(bot) }
      Divider()
      Button("Delete Bot…", systemImage: "trash", role: .destructive) { deletingBot = bot }
    }
    .help(bot.rootPath)
    .id(bot.id)
  }
}

struct SidebarBotsModifier: ViewModifier {
  @Environment(AppEnvironment.self) private var environment
  @Binding var botEditor: BotEditorTarget?
  @Binding var deletingBot: Bot?
  @Binding var selection: SidebarSelection?

  func body(content: Content) -> some View {
    content
      .sheet(item: $botEditor) { target in
        BotEditorSheet(target: target, environment: environment) { bot in
          selection = .bot(serverId: bot.serverId, id: bot.id)
        }
      }
      .confirmationDialog(
        "Delete \(deletingBot?.name ?? "bot")?",
        isPresented: Binding(get: { deletingBot != nil }, set: { if !$0 { deletingBot = nil } }),
        titleVisibility: .visible,
        presenting: deletingBot
      ) { bot in
        Button("Delete Bot", role: .destructive) { delete(bot) }
      } message: { bot in
        Text(environment.botDeletionMessage(for: bot))
      }
  }

  private func delete(_ bot: Bot) {
    if selection == .bot(serverId: bot.serverId, id: bot.id) {
      selection = .newChat(nil)
    }
    Task {
      do {
        try await environment.bots.delete(bot)
      } catch {
        ErrorReporter.shared.report("Couldn't delete bot", error: error)
      }
    }
  }
}
