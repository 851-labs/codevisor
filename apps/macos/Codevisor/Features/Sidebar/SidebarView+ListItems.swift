import CodevisorCore
import Foundation

extension SidebarView {
  /// The listed workspaces in display order, precomputed by the navigation
  /// store and limited here to machines this Mac knows.
  var visibleSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  /// The chat a workspace routes through: its first routing chat that the
  /// sidebar shows (imported chats only when enabled), else any routing chat
  /// still known to the session list -- a terminal-only workspace routes
  /// through a closed chat that still belongs to it.
  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    var fallback: ChatSession?
    for id in item.routingChatIds {
      guard let session = list.session(id, serverId: item.serverId) else { continue }
      if session.origin == .codevisor || list.showsImportedSessions { return session }
      if fallback == nil { fallback = session }
    }
    return fallback
  }

  /// A listed workspace's current value with its routing chat. Nil once the
  /// workspace is gone.
  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      !workspace.isArchived
    else { return nil }
    return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
  }

  /// Every listed workspace resolved. For actions that need the whole list
  /// (keyboard stepping, reordering) -- never read from a view body.
  var listedWorkspaceItems: [SidebarWorkspaceListItem] {
    visibleSidebarItems.compactMap(listItem(for:))
  }
}
