import CodevisorCore
import Foundation

extension ClassicSidebarView {
  var listedSidebarItems: [WorkspaceSidebarItem] {
    environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil
    }
  }

  func routingSession(for item: WorkspaceSidebarItem) -> ChatSession? {
    var fallback: ChatSession?
    for id in item.routingChatIds {
      guard let session = list.session(id, serverId: item.serverId) else { continue }
      if session.origin == .codevisor || list.showsImportedSessions { return session }
      if fallback == nil { fallback = session }
    }
    return fallback
  }

  func listItem(for item: WorkspaceSidebarItem) -> SidebarWorkspaceListItem? {
    guard let workspace = environment.navigationStore.workspaceEntries.entry(item.id).workspace,
      !workspace.isArchived
    else { return nil }
    return SidebarWorkspaceListItem(workspace: workspace, routingSession: routingSession(for: item))
  }

  var listedWorkspaceItems: [SidebarWorkspaceListItem] {
    listedSidebarItems.compactMap(listItem(for:))
  }
}
