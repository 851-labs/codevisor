import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSAgentRowView: View {
  let row: IOSAgentRow
  let actions: IOSAgentRowActions

  private var isUnread: Bool { row.chat.isUnread }

  private var unreadTitle: String { isUnread ? "Mark as Read" : "Mark as Unread" }

  private func toggleUnread() { actions.setUnread(!isUnread) }

  var body: some View {
    Button(action: actions.open) {
      HomeSidebarRowLabel(details: row.details)
    }
    .tint(.primary)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button(action: toggleUnread) {
        Image(systemName: isUnread ? "message" : "message.badge")
      }
      .tint(.blue)
      .accessibilityLabel(unreadTitle)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if let archive = actions.archive {
        Button(action: archive) {
          Image(systemName: "archivebox")
        }
        .tint(.indigo)
        .accessibilityLabel("Archive")
      }
      if let rename = actions.rename {
        Button(action: rename) {
          Image(systemName: "pencil")
        }
        .tint(.gray)
        .accessibilityLabel("Rename")
      }
    }
    .contextMenu { menu }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.details.accessibilityLabel)
    .accessibilityActions {
      Button(unreadTitle, action: toggleUnread)
      if let rename = actions.rename {
        Button("Rename", action: rename)
      }
      if let archive = actions.archive {
        Button("Archive", action: archive)
      }
    }
    .accessibilityIdentifier("agents.row.\(row.details.title)")
  }

  @ViewBuilder
  private var menu: some View {
    UnreadMenuItem(isUnread: isUnread, setUnread: actions.setUnread)
    if let rename = actions.rename {
      Divider()
      Button(action: rename) {
        Label("Rename", systemImage: "pencil")
      }
    }
    if let archive = actions.archive {
      Divider()
      Button(action: archive) {
        Label("Archive", systemImage: "archivebox")
      }
    }
  }
}
