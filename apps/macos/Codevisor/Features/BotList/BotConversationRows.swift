import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers

struct BotConversationRows: View {
  let rows: [BotSidebarRow]
  let sections: [BotSection]
  let selectedBotID: UUID?
  let actions: BotSidebarRowActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: BotSidebarDrag?
  @State private var dropTarget: BotSidebarRowID?

  var body: some View {
    TimelineView(.everyMinute) { context in
      SidebarRowList(rows: rows, id: \.placedID, spacing: 2, animation: Motion.listReflow(reduceMotion: reduceMotion)) {
        row($0, now: context.date)
          .onDrop(
            of: [.plainText],
            delegate: BotSidebarDropDelegate(
              target: $0.id, drag: $drag, dropTarget: $dropTarget, perform: dropAction(onto: $0)))
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private func row(_ row: BotSidebarRow, now: Date) -> some View {
    switch row.kind {
    case let .bot(conversation, section):
      botRow(conversation, section: section, now: now)
    case let .section(section, isExpanded):
      BotSectionHeader(
        section: section, isExpanded: isExpanded, isDropTarget: dropTarget == row.id, actions: actions
      )
      .onDrag { start(.section(section.id)) }
    }
  }

  private func botRow(_ conversation: BotConversation, section: UUID?, now: Date) -> some View {
    let bot = conversation.bot
    return BotConversationRow(
      conversation: conversation, isSelected: bot.id == selectedBotID,
      isDropTarget: dropTarget == .bot(bot.id), now: now
    )
    .onTapGesture { actions.select(bot) }
    .accessibilityAction(.default) { actions.select(bot) }
    .onDrag { start(.bot(bot.id)) }
    .contextMenu {
      Button {
        actions.edit(bot)
      } label: {
        Label("Edit", systemImage: "pencil")
          .labelStyle(.titleAndIcon)
      }
      BotMoveToSectionMenu(bot: bot, currentSectionID: section, sections: sections, actions: actions)
      Divider()
      Button(role: .destructive) {
        actions.delete(bot)
      } label: {
        Label("Delete", systemImage: "trash")
          .labelStyle(.titleAndIcon)
      }
    }
    .id(bot.id)
  }

  private func start(_ drag: BotSidebarDrag) -> NSItemProvider {
    self.drag = drag
    return drag.itemProvider
  }

  private func dropAction(onto row: BotSidebarRow) -> (() -> Void)? {
    switch (drag, row.kind) {
    case let (.bot(botID)?, .bot(conversation, section)) where conversation.id != botID:
      { actions.moveBot(botID, section) }
    case let (.bot(botID)?, .section(section, _)):
      { actions.moveBot(botID, section.id) }
    case let (.section(sectionID)?, .section(section, _)) where section.id != sectionID:
      sections.firstIndex(where: { $0.id == section.id }).map { index in { actions.moveSection(sectionID, index) } }
    default:
      nil
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
    case .section: BotPlacedRowID(id: id, section: nil)
    }
  }
}
