import CodevisorCore
import Foundation

struct HomeSidebarBot: Identifiable, Equatable {
  let bot: Bot
  let status: HomeSessionStatus
  let machine: HomeSidebarRowMachine?
  let home: HomeSidebarWorkspace?
  let children: [HomeSidebarWorkspace]
  var canArchive = false

  var id: UUID { bot.id }

  var tabs: [HomeSidebarTabRow] {
    home?.rows.filter { $0.chatSessionId != bot.sessionId } ?? []
  }

  var hasNestedRows: Bool { !tabs.isEmpty || !children.isEmpty }
}
