import CodevisorCore
import Foundation
import UIKit

/// One workspace section of the sidebar: the workspace's identity plus one
/// row per open tab, resolved from the repository into plain values so the
/// list renders identically for live data, previews, and fixtures.
struct HomeSidebarSection: Identifiable, Equatable {
  let id: UUID
  let serverId: String
  let name: String
  /// The owning machine, shown only in multi-machine fleets.
  let machineName: String?
  /// The chat the workspace mounts through: iOS opens a workspace by its
  /// anchor chat, whatever tab it then shows.
  let anchorSessionId: UUID
  /// The most urgent tab status, summarized on a collapsed header.
  let status: HomeSessionStatus
  let rows: [HomeSidebarTabRow]

  var displayName: String { name.isEmpty ? "Workspace" : name }
}

/// One tab of a workspace as a sidebar row. Mirrors the macOS sidebar's
/// per-tab rows: chats, terminals, browsers, plugins, documents, and the
/// New Tab placeholder all list alike.
struct HomeSidebarTabRow: Identifiable, Equatable {
  enum Icon: Equatable {
    case chat(harnessId: String, fallbackSymbolName: String)
    case terminal(isAgentOwned: Bool)
    case browser(favicon: UIImage?)
    case plugin(pluginId: String, paneType: String?)
    case document
    case newTab
  }

  /// The pane id.
  let id: UUID
  let title: String
  let icon: Icon
  /// Chat rows carry their live status; it replaces the icon, as on macOS.
  let status: HomeSessionStatus
  /// Chat rows: the session they open.
  let chatSessionId: UUID?
  /// The single-pane center tab this row names, whose title can be pinned.
  /// Nil for panes inside a split or the bottom panel, which have no title
  /// of their own.
  let renamableTabId: UUID?
}
