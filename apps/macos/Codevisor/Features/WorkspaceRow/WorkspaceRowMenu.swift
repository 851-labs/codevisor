import CodevisorCore
import SwiftUI

struct WorkspaceRowMenu: View {
  let lifecycle: WorkspaceRowLifecycle
  let unreadChat: ChatSession?

  var body: some View {
    switch lifecycle {
    case let .active(actions):
      WorkspaceRowActiveMenu(actions: actions, unreadChat: unreadChat)
    case let .archived(onRestore):
      Button(action: onRestore) {
        Label("Restore", systemImage: "arrow.uturn.backward")
          .labelStyle(.titleAndIcon)
      }
    }
  }
}

private struct WorkspaceRowActiveMenu: View {
  let actions: WorkspaceRowActions
  let unreadChat: ChatSession?

  var body: some View {
    if let unreadChat {
      ChatSessionUnreadMenuItem(session: unreadChat)
      Divider()
    }
    Button(action: actions.togglePin) {
      Label(actions.isPinned ? "Unpin" : "Pin", systemImage: actions.isPinned ? "pin.slash" : "pin")
        .labelStyle(.titleAndIcon)
    }
    Button(action: actions.rename) {
      Label("Rename", systemImage: "pencil")
        .labelStyle(.titleAndIcon)
    }
    if let sectionMenu = actions.sectionMenu {
      Divider()
      sectionMenu
    }
    Divider()
    Button(action: actions.archive) {
      Label("Archive", systemImage: "archivebox")
        .labelStyle(.titleAndIcon)
    }
    .shortcut(.archiveWorkspace)
  }
}
