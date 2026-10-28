import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotConversationRows: View {
  let rows: [BotSidebarRow]
  let selectedBotID: UUID?
  let onSelect: (Bot) -> Void
  let onEdit: (Bot) -> Void
  let onDelete: (Bot) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if rows.isEmpty {
      BotListPlaceholder()
        .containerRelativeFrame(.vertical)
    } else {
      list
    }
  }

  private var list: some View {
    TimelineView(.everyMinute) { context in
      SidebarRowList(rows: rows, id: \.id, spacing: 2, animation: Motion.listReflow(reduceMotion: reduceMotion)) {
        row($0, now: context.date)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private func row(_ row: BotSidebarRow, now: Date) -> some View {
    switch row.kind {
    case let .bot(conversation):
      botRow(conversation, now: now)
    }
  }

  private func botRow(_ conversation: BotConversation, now: Date) -> some View {
    let bot = conversation.bot
    return BotConversationRow(conversation: conversation, isSelected: bot.id == selectedBotID, now: now)
      .onTapGesture { onSelect(bot) }
      .accessibilityAction(.default) { onSelect(bot) }
      .contextMenu {
        Button("Edit Bot…", systemImage: "pencil") { onEdit(bot) }
        Divider()
        Button("Delete Bot…", systemImage: "trash", role: .destructive) { onDelete(bot) }
      }
      .id(bot.id)
  }
}
