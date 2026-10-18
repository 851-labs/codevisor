import CodevisorCore
import Foundation

struct HomeSidebarBot: Identifiable, Equatable {
  let bot: Bot
  let status: HomeSessionStatus
  let machine: HomeSidebarRowMachine?
  let children: [HomeSidebarWorkspace]

  var id: UUID { bot.id }
}
