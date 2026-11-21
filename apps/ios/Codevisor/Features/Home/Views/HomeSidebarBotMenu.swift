import CodevisorCore
import Foundation

struct HomeSidebarBotMenu {
  let bot: HomeSidebarBot
  let actions: HomeSidebarActionHandler
  var sections: [CustomSection]?

  private var isArchived: Bool { bot.bot.isArchived }

  private var offersArchive: Bool { bot.canArchive && !isArchived }

  var menu: HomeSidebarMenu {
    var menu = HomeSidebarMenu()
    if isArchived {
      menu.add(.action("Unarchive", systemImage: "arrow.uturn.backward") { actions.actions.unarchiveBot(bot.bot) })
    } else {
      menu.add(.unread(isUnread: bot.conversation.isUnread, setUnread: setUnread))
      menu.add(editing)
      menu.add(moveToSection)
    }
    menu.add(removal)
    return menu
  }

  private var editing: [HomeSidebarMenu.Item] {
    let edit = HomeSidebarMenu.Item.action("Edit", systemImage: "pencil") { actions.actions.editBot(bot.bot) }
    guard bot.canFork else { return [edit] }
    return [edit, .action("Fork…", systemImage: "arrow.triangle.branch") { actions.actions.forkBot(bot.bot) }]
  }

  private var moveToSection: [HomeSidebarMenu.Item] {
    guard let sections else { return [] }
    return [
      HomeSidebarMoveToSectionMenu.item(
        currentSectionID: bot.sectionID, sections: sections,
        move: { actions.actions.botSections.move(bot.bot.id, $0) },
        newSection: { actions.actions.botSections.create(bot.bot.id) })
    ]
  }

  private var removal: HomeSidebarMenu.Item {
    guard offersArchive else {
      return .action("Delete…", systemImage: "trash", isDestructive: true) { actions.actions.deleteBot(bot.bot) }
    }
    return .action("Archive", systemImage: "archivebox") { actions.actions.archiveBot(bot.bot) }
  }

  private func setUnread(_ isUnread: Bool) {
    actions.actions.setUnread(bot.bot.sessionId, bot.bot.serverId, isUnread)
  }
}
