import CodevisorCore
import Foundation

extension SidebarView {
  /// The listed workspaces in their saved order, precomputed by the
  /// navigation store and limited here to machines this Mac knows.
  var listedSidebarItems: [WorkspaceSidebarItem] {
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

  /// The listed workspaces split by the sidebar's grouping. Reads only the
  /// precomputed list (each item carries its machine and project), the
  /// project list, and the machines.
  var workspaceGroups: [SidebarWorkspaceGroup] {
    let items = listedSidebarItems
    switch grouping {
    case .flat:
      return [SidebarWorkspaceGroup(id: "all", title: nil, items: items)]
    case .machine:
      return SidebarWorkspaceGroup.grouping(items, by: \.serverId) { item in
        (machineName(forServer: item.serverId) ?? "Unknown Machine", nil)
      }
    case .project:
      let names = Dictionary(
        list.projects.map { ("\($0.serverId)/\($0.id)", $0.name) }, uniquingKeysWith: { first, _ in first })
      return SidebarWorkspaceGroup.grouping(items, by: { "\($0.serverId)/\($0.projectId)" }) { item in
        (names["\(item.serverId)/\(item.projectId)"] ?? "Unknown Project", machineName(forServer: item.serverId))
      }
    }
  }

  /// Every listed workspace resolved, in the order the sidebar shows them.
  /// For actions that need the whole list (keyboard stepping) -- never read
  /// from a view body.
  var listedWorkspaceItems: [SidebarWorkspaceListItem] {
    workspaceGroups.flatMap(\.items).compactMap(listItem(for:))
  }
}
