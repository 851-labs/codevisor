import CodevisorCore
import SwiftUI

struct BotConversationRows: View {
  let conversations: [BotConversation]
  let selectedBotID: UUID?
  let onSelect: (Bot) -> Void
  let onEdit: (Bot) -> Void
  let onDelete: (Bot) -> Void

  var body: some View {
    if conversations.isEmpty {
      BotListPlaceholder()
        .containerRelativeFrame(.vertical)
    } else {
      list
    }
  }

  private var list: some View {
    TimelineView(.everyMinute) { context in
      LazyVStack(spacing: 2) {
        ForEach(conversations) { conversation in
          row(conversation, now: context.date)
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
  }

  private func row(_ conversation: BotConversation, now: Date) -> some View {
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
