import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotRowReorderOverlay: View {
  let reorder: BotRowReorder
  let rows: [BotSidebarRow]

  var body: some View {
    if let drag = reorder.drag {
      ZStack(alignment: .topLeading) {
        ghost(drag)
        if let line = reorder.insertionLine(in: rows) {
          SidebarInsertionLine()
            .frame(width: line.width, height: SidebarInsertionLine.height)
            .position(x: line.midX, y: line.minY)
        }
      }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private func ghost(_ drag: BotRowDrag) -> some View {
    if let conversation = rows.lazy.compactMap(\.activeConversation).first(where: { $0.id == drag.botID }) {
      let frame = drag.ghostFrame
      BotConversationRow(conversation: conversation, isSelected: false)
        .frame(width: frame.width, height: frame.height)
        .sidebarDragLift()
        .position(x: frame.midX, y: frame.midY)
    }
  }
}

extension BotSidebarRow {
  fileprivate var activeConversation: BotConversation? {
    guard case let .bot(conversation, _) = kind else { return nil }
    return conversation
  }
}
