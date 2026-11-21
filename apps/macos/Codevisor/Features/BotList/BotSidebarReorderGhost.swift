import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotSidebarReorderGhost: View {
  let lifted: SidebarReorder<BotSidebarRowID>.Lifted
  let rows: [BotSidebarRow]

  var body: some View {
    switch rows.first(where: { $0.id == lifted.row })?.kind {
    case let .bot(conversation, _):
      BotConversationRow(conversation: conversation, isSelected: false)
    case let .section(section, _):
      SidebarHeaderGhost(title: section.name)
    default:
      EmptyView()
    }
  }
}
