import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationRows: View {
  let rows: [BotSidebarRow]
  let sections: [CustomSection]
  let selectedBotID: UUID?
  let actions: BotSidebarRowActions
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var reorder = SidebarReorder<BotSidebarRowID>()

  var body: some View {
    SidebarRowList(rows: rows, id: \.placedID, spacing: 2, animation: Motion.listReflow(reduceMotion: reduceMotion)) {
      row($0)
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 8)
    .coordinateSpace(SidebarReorderSpace.coordinateSpace)
    .overlay(alignment: .topLeading) {
      SidebarReorderOverlay(reorder: reorder) { BotSidebarReorderGhost(lifted: $0, rows: rows) }
    }
  }

  @ViewBuilder
  private func row(_ row: BotSidebarRow) -> some View {
    switch row.kind {
    case let .bot(conversation, section):
      botRow(conversation, section: section)
    case let .section(section, isExpanded):
      sectionHeader(section, isExpanded: isExpanded)
    case let .archivedSection(isExpanded):
      SidebarSectionHeader(title: "Archived", isExpanded: isExpanded, onToggle: actions.toggleArchived)
    case let .archivedBot(conversation):
      archivedBotRow(conversation)
    }
  }

  private func botRow(_ conversation: BotConversation, section: UUID?) -> some View {
    let bot = conversation.bot
    return BotConversationRow(conversation: conversation, isSelected: bot.id == selectedBotID)
      .onSidebarRowPress { actions.select(bot) }
      .accessibilityAction(.default) { actions.select(bot) }
      .modifier(
        SidebarReorderable(
          reorder: reorder, row: .bot(bot.id),
          lift: { reorder.liftItem(bot.id, row: .bot(bot.id), in: BotSidebarRows.dropRegion(in: rows)) },
          commit: { commit($0, bot: bot) })
      )
      .contextMenu {
        if let chat = chat(of: bot) {
          ChatSessionUnreadMenuItem(session: chat)
          Divider()
        }
        Button {
          actions.edit(bot)
        } label: {
          Label("Edit", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
        Button {
          actions.fork(bot)
        } label: {
          Label("Fork…", systemImage: "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
        }
        Divider()
        MoveToSectionMenu(
          currentSectionID: section, sections: sections, move: { actions.moveBot(bot.id, $0) },
          newSection: { actions.newSection(bot) })
        Divider()
        Button {
          actions.archive(bot)
        } label: {
          Label("Archive", systemImage: "archivebox")
            .labelStyle(.titleAndIcon)
        }
        .shortcut(.archiveWorkspace)
      }
      .id(bot.id)
  }

  private func archivedBotRow(_ conversation: BotConversation) -> some View {
    let bot = conversation.bot
    return BotConversationRow(conversation: conversation, isSelected: bot.id == selectedBotID)
      .opacity(0.6)
      .onSidebarRowPress { actions.select(bot) }
      .accessibilityAction(.default) { actions.select(bot) }
      .accessibilityValue("Archived")
      .contextMenu {
        Button {
          actions.unarchive(bot)
        } label: {
          Label("Unarchive", systemImage: "arrow.uturn.backward")
            .labelStyle(.titleAndIcon)
        }
        Divider()
        deleteButton(bot)
      }
      .id(bot.id)
  }

  private func chat(of bot: Bot) -> ChatSession? {
    environment.projectList.session(bot.sessionId, serverId: bot.serverId)
  }

  private func deleteButton(_ bot: Bot) -> some View {
    Button(role: .destructive) {
      actions.delete(bot)
    } label: {
      Label("Delete…", systemImage: "trash")
        .labelStyle(.titleAndIcon)
    }
  }

  private func sectionHeader(_ section: CustomSection, isExpanded: Bool) -> some View {
    CustomSectionHeader(
      section: section, isExpanded: isExpanded,
      onToggle: { if reorder.allowsToggle { actions.toggleSection(section.id) } },
      actions: CustomSectionActions(
        sections: sections, section: section, rename: actions.renameSection, delete: actions.deleteSection,
        move: actions.moveSection)
    )
    .modifier(SidebarReorderHighlight(reorder: reorder, section: section.id))
    .modifier(
      SidebarReorderable(
        reorder: reorder, row: .section(section.id),
        lift: { reorder.liftBlock(.section(section.id), in: BotSidebarRows.sectionBlocks(in: rows)) },
        commit: { commit($0, section: section) }))
  }

  private func commit(_ drop: SidebarReorder<BotSidebarRowID>.Drop, section: CustomSection) {
    guard case let .block(index) = drop.target else { return }
    actions.moveSection(section.id, index)
  }

  private func commit(_ drop: SidebarReorder<BotSidebarRowID>.Drop, bot: Bot) {
    guard case let .item(id, region) = drop.lifted.lift, case let .item(target) = drop.target else { return }

    switch target {
    case let .header(section):
      actions.moveBot(id, section)
    case let .insertion(index):
      actions.placeBot(bot, region.placement(insertingAt: index, excluding: id))
    }
  }
}

private struct BotPlacedRowID: Hashable {
  let id: BotSidebarRowID
  let section: UUID?
}

extension BotSidebarRow {
  fileprivate var placedID: BotPlacedRowID {
    switch kind {
    case let .bot(_, section): BotPlacedRowID(id: id, section: section)
    case .section, .archivedSection, .archivedBot: BotPlacedRowID(id: id, section: nil)
    }
  }
}
