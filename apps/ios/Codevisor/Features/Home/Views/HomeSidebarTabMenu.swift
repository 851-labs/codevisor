import CodevisorCore
import Foundation

struct HomeSidebarTabMenu {
  let row: HomeSidebarTabRow
  let workspace: HomeSidebarWorkspaceRef
  let actions: HomeSidebarActionHandler

  var menu: HomeSidebarMenu {
    var menu = HomeSidebarMenu()
    menu.add(unread)
    menu.add(openInNewWindow)
    menu.add(close)
    return menu
  }

  private var unread: [HomeSidebarMenu.Item] {
    guard let chatId = row.chatSessionId else { return [] }
    return [.unread(isUnread: row.isUnread) { actions.actions.setUnread(chatId, workspace.serverId, $0) }]
  }

  private var openInNewWindow: [HomeSidebarMenu.Item] {
    guard let open = actions.actions.openInNewWindow else { return [] }
    return [.action("Open in New Window", systemImage: "macwindow.badge.plus") { open(row, workspace) }]
  }

  private var close: [HomeSidebarMenu.Item] {
    guard !row.isMainChat else { return [] }
    return [.action("Close Tab", systemImage: "xmark", isDestructive: true) { actions.actions.close(row, workspace) }]
  }
}
