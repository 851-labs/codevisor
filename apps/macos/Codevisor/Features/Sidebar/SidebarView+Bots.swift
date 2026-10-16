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
    let bots = environment.bots.bots
    if botsEnabled, canCreateBots || !bots.isEmpty {
      SidebarSectionHeader(
        title: "Bots",
        isExpanded: botsExpanded,
        onToggle: { fold(Self.botsFoldID) { botsExpanded.toggle() } },
        add: SidebarSectionHeader.Add(help: "New Bot") { botEditor = .create }
      )
      let isFolding = folds.isFolding(Self.botsFoldID)
      SidebarFoldingList(shows: botsExpanded) { progress in
        ForEach(bots) { bot in
          let children = botChildren(of: bot)
          VStack(alignment: .leading, spacing: 1) {
            botRow(bot, hasChildren: !children.isEmpty)
            if !children.isEmpty {
              botChildList(children, groupID: Self.botGroupID(bot))
                .padding(.leading, Self.groupIndent)
            }
          }
          .sidebarFoldingRow(
            isFolding && bot.id != selectedBotID && !children.contains { $0.id == selectedWorkspaceID },
            progress: progress, shows: botsExpanded)
        }
        if bots.isEmpty {
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

  var botNestedWorkspaceIDs: Set<UUID> {
    guard botsEnabled else { return [] }
    let bots = environment.bots.bots
    let children = bots.flatMap { botChildren(of: $0) }
    return Set(bots.map(\.workspaceId) + children.map(\.id))
  }

  static func botGroupID(_ bot: Bot) -> String { "bot:\(bot.serverId)|\(bot.id.uuidString)" }

  func botChildren(of bot: Bot) -> [WorkspaceSidebarItem] {
    (environment.navigationStore.workspaceEntries.botChildren[bot.id] ?? []).filter {
      $0.serverId == bot.serverId
    }
  }

  func botChildren(containing id: UUID) -> [WorkspaceSidebarItem]? {
    environment.navigationStore.workspaceEntries.botChildren.values.first { $0.contains { $0.id == id } }
  }

  private func botChildList(_ children: [WorkspaceSidebarItem], groupID: String) -> some View {
    let isExpanded = !collapsedGroupIDs.contains(groupID)
    guard folds.isFolding(groupID) else {
      let visible = isExpanded ? children : children.filter { $0.id == selectedWorkspaceID }
      let rows = withReleasedRows(visible, from: children)
      return workspaceList(rows.items, folding: [], releasing: rows.releasing, shows: isExpanded)
    }
    let folding = Set(children.map(\.id)).subtracting([selectedWorkspaceID].compactMap { $0 })
    return workspaceList(children, folding: folding, releasing: [], shows: isExpanded)
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
      systemImage: bot.symbolName,
      isSelected: selection == .bot(serverId: bot.serverId, id: bot.id),
      isHoverEnabled: !isReordering,
      isExpanded: hasChildren ? !collapsedGroupIDs.contains(groupID) : nil,
      onSelect: { selection = .bot(serverId: bot.serverId, id: bot.id) },
      onToggle: { toggleBotGroup(groupID) }
    )
    .contextMenu {
      Button("Edit Bot…", systemImage: "pencil") { botEditor = .edit(bot) }
      Divider()
      Button("Delete Bot…", systemImage: "trash", role: .destructive) { deletingBot = bot }
    }
    .help(bot.rootPath)
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
        BotEditorSheet(target: target, defaultServerId: defaultServerId) { bot in
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
        Text(deleteMessage(for: bot))
      }
  }

  private func deleteMessage(for bot: Bot) -> String {
    let removal =
      "The bot's chat, its worktrees in \(bot.rootPath), and their codevisor/bot branches will be removed. Uncommitted and unpushed work in those worktrees will be lost."
    let workspaces = environment.navigationStore.workspaceEntries.botChildren[bot.id]?.count ?? 0
    switch workspaces {
    case 0: return removal
    case 1: return removal + " Its workspace will be archived."
    default: return removal + " Its \(workspaces) workspaces will be archived."
    }
  }

  private var defaultServerId: String {
    let preferred = environment.defaultComposerServerId
    if environment.bots.supportsBots(on: preferred) { return preferred }
    return environment.bots.botMachines.first?.id ?? preferred
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
