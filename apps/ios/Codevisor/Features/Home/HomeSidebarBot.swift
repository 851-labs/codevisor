import CodevisorCore
import Foundation

struct HomeSidebarBot: Identifiable, Equatable {
  let conversation: BotConversation
  let status: HomeSessionStatus
  let machine: HomeSidebarRowMachine?
  let home: HomeSidebarWorkspace?
  var canArchive = false
  var canFork = false
  var sectionID: UUID?

  var id: UUID { bot.id }

  var bot: Bot { conversation.bot }

  var tabs: [HomeSidebarTabRow] {
    home?.rows.filter { $0.chatSessionId != bot.sessionId } ?? []
  }

  var hasNestedRows: Bool { !tabs.isEmpty }
}
