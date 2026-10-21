import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var canCreateBots: Bool {
    botsEnabled && !environment.bots.botMachines.isEmpty
  }

  var selectedBotID: UUID? {
    if case let .bot(_, id) = selection { return id }
    return nil
  }

  var botEntries: [BotSidebarEntry] {
    botsEnabled ? environment.botSidebarEntries : []
  }

  var botNestedWorkspaceIDs: Set<UUID> {
    Set(botEntries.flatMap(\.workspaceIDs))
  }

  func isBotSelected(_ bot: Bot) -> Bool {
    bot.id == selectedBotID || bot.workspaceId == selectedWorkspaceID
  }

  static func botGroupID(_ bot: Bot) -> String { SidebarRows.Bot.groupID(serverId: bot.serverId, id: bot.id) }

  func botChildren(containing id: UUID) -> [WorkspaceSidebarItem]? {
    environment.navigationStore.workspaceEntries.botChildren.values.first { $0.contains { $0.id == id } }
  }

  func toggleBotGroup(_ groupID: String) {
    if collapsedGroupIDs.contains(groupID) {
      collapsedGroupIDs.removeAll { $0 == groupID }
    } else {
      collapsedGroupIDs.append(groupID)
    }
  }

  func botRow(_ bot: Bot, isExpanded: Bool?) -> some View {
    SidebarBotRow(
      title: bot.name,
      icon: SidebarBotIcon(bot: bot, store: store),
      isSelected: isBotSelected(bot),
      isHoverEnabled: !isReordering,
      isExpanded: isExpanded,
      onSelect: { selection = .bot(serverId: bot.serverId, id: bot.id) },
      onToggle: { toggleBotGroup(Self.botGroupID(bot)) }
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
        Text(Bot.deletionMessage)
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
