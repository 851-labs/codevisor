import CodevisorCore
import SwiftUI

struct WorkspaceRowMenu: View {
  let lifecycle: WorkspaceRowLifecycle
  let unreadChat: ChatSession?

  var body: some View {
    switch lifecycle {
    case let .active(actions):
      WorkspaceRowActiveMenu(actions: actions, unreadChat: unreadChat)
    case .fixed:
      if let unreadChat {
        ChatSessionUnreadMenuItem(session: unreadChat)
      }
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
    if let pin = actions.pin {
      Button(action: pin.toggle) {
        Label(pin.title, systemImage: pin.systemImage)
          .labelStyle(.titleAndIcon)
      }
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
