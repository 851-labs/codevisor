import CodevisorCore
import CodevisorUI
import Foundation

struct HomeSidebarBot: Identifiable, Equatable {
  let conversation: BotConversation
  let status: HomeSessionStatus
  let machine: HomeSidebarRowMachine?
  let home: HomeSidebarWorkspace?
  var canArchive = false
  var canFork = false
  var sectionID: UUID?
  var rowStatus: SidebarRowStatus? = nil
  var showsStatusLabel = false

  var id: UUID { bot.id }

  var bot: Bot { conversation.bot }

  var tabs: [HomeSidebarTabRow] {
    home?.rows.filter { $0.chatSessionId != bot.sessionId } ?? []
  }

  var hasNestedRows: Bool { !tabs.isEmpty }
}
