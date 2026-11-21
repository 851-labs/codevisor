import CodevisorCore
import CodevisorUI
import Foundation

struct HomeSidebarWorkspaceMenu {
  let workspace: HomeSidebarWorkspace
  let actions: HomeSidebarActionHandler
  var sections: [CustomSection] = []

  private var ref: HomeSidebarWorkspaceRef { workspace.workspace }

  var menu: HomeSidebarMenu {
    var menu = HomeSidebarMenu()
    guard !workspace.isArchived else {
      menu.add(.action("Restore", systemImage: "arrow.uturn.backward") { actions.actions.restoreWorkspace(ref) })
      return menu
    }

    menu.add(unread)
    menu.add(openInNewWindow)
    menu.add(editing)
    menu.add(moveToSection)
    menu.add(.action("Archive", systemImage: "archivebox") { actions.actions.archiveWorkspace(ref) })
    return menu
  }

  private var unread: [HomeSidebarMenu.Item] {
    guard let chat = workspace.mainChatRow, let chatId = chat.chatSessionId else { return [] }
    return [.unread(isUnread: chat.isUnread) { actions.actions.setUnread(chatId, workspace.serverId, $0) }]
  }

  private var openInNewWindow: [HomeSidebarMenu.Item] {
    guard let open = actions.actions.openWorkspaceInNewWindow else { return [] }
    return [.action("Open in New Window", systemImage: "macwindow.badge.plus") { open(workspace) }]
  }

  private var editing: [HomeSidebarMenu.Item] {
    var items: [HomeSidebarMenu.Item] = []
    if workspace.canPin { items.append(pin) }
    items.append(.action("New Tab", systemImage: "plus.square.on.square") { actions.actions.newTab(ref) })
    items.append(.action("Rename", systemImage: "pencil") { actions.actions.renameWorkspace(ref) })
    return items
  }

  private var pin: HomeSidebarMenu.Item {
    .action(workspace.isPinned ? "Unpin" : "Pin", systemImage: workspace.isPinned ? "pin.slash" : "pin") {
      actions.actions.togglePin(ref)
    }
  }

  private var moveToSection: [HomeSidebarMenu.Item] {
    guard let slot = workspace.sectionSlot else { return [] }
    return [
      HomeSidebarMoveToSectionMenu.item(
        currentSectionID: slot.sectionID, sections: sections,
        move: { actions.actions.workspaceSections.move(ref.id, $0) },
        newSection: { actions.actions.workspaceSections.create(ref.id) })
    ]
  }
}
