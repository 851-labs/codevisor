import SwiftUI
import CodevisorCore
import CodevisorUI

extension SidebarView {
  var rowContent: SidebarRowContent {
    SidebarRowContent(environment: environment, store: store, grouping: grouping, rowDetails: rowDetails)
  }

  var rowActions: SidebarWorkspaceSection.Actions {
    SidebarWorkspaceSection.Actions(
      activate: { activateWorkspace($0) },
      togglePin: { togglePin($0) },
      newTab: { addTab(in: $0) },
      rename: { workspace in
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      archive: { archiveWorkspace($0) }
    )
  }

  func row(
    for workspace: Workspace,
    icon: SidebarWorkspaceIcon,
    isSelected: Bool,
    onActivate: @escaping () -> Void,
    lifecycle: SidebarWorkspaceRow.Lifecycle
  ) -> SidebarWorkspaceRow {
    let content = rowContent
    let isPinned = isPinned(workspace)
    return SidebarWorkspaceRow(
      name: workspace.name,
      subtitle: content.subtitle(for: workspace, isPinned: isPinned),
      icon: icon,
      store: store,
      pullRequest: content.pullRequest(for: workspace),
      machine: content.machine(for: workspace, isPinned: isPinned),
      isSelected: isSelected,
      isReordering: isReordering,
      onActivate: onActivate,
      lifecycle: lifecycle
    )
  }

  func machineName(forServer serverId: String) -> String? {
    rowContent.machineName(forServer: serverId)
  }

  func rowSubtitle(for workspace: Workspace) -> String? {
    rowContent.subtitle(for: workspace, isPinned: isPinned(workspace))
  }

  var gitLookupRefreshKey: SidebarGitLookups.RefreshKey? {
    guard store != nil else { return nil }
    return SidebarGitLookups.refreshKey(
      details: rowDetails, workspaceIds: listedSidebarItems.map(\.id),
      archivedWorkspaceIds: visibleArchivedItems.map(\.id))
  }

  func refreshGitLookups() {
    store?.gitLookups.refresh(
      active: listedWorkspaceItems.map(\.workspace), archived: listedArchivedWorkspaces,
      listedIds: listedSidebarItems.map(\.id), details: rowDetails, client: environment.machines.client(for:)
    )
  }

  func icon(for item: SidebarWorkspaceListItem) -> SidebarWorkspaceIcon {
    rowContent.icon(for: item)
  }

  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .archivedWorkspace, .bot, .newChat, .none:
      return false
    }
  }

  func activateWorkspace(_ item: SidebarWorkspaceListItem) {
    guard let tab = item.workspace.selectedCenterTab ?? item.workspace.centerTabs.first else { return }
    activateTab(tab, in: item)
  }

  func activateTab(_ tab: WorkspaceTab, in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    guard store?.selectDestination(.tab(tab.id), in: workspace.id) == true else { return }
    apply(
      workspace.selectionRoute(
        activatedChatSessionId: routableChat(in: tab, serverId: workspace.serverId)?.id,
        routingSessionId: item.routingSession?.id,
        selectionAlreadyRoutesWorkspace: routesSelectedSession(workspace)
      ))
  }

  func stepWorkspace(_ offset: Int) {
    let items = listedWorkspaceItems
    let archived = listedArchivedWorkspaces
    let current: Int? =
      if isNewChatSelected {
        0
      } else if let index = items.firstIndex(where: { routesSelectedSession($0.workspace) }) {
        index + 1
      } else if case let .archivedWorkspace(serverId, id) = selection,
        let index = archived.firstIndex(where: { $0.serverId == serverId && $0.id == id })
      {
        items.count + 1 + index
      } else {
        nil
      }
    guard let current else { return }
    let target = current + offset
    guard target != current, (0...items.count + archived.count).contains(target) else { return }
    if target == 0 {
      selection = .newChat(nil)
    } else if target <= items.count {
      let item = items[target - 1]
      revealRequest.workspaceID = item.workspace.id
      activateWorkspace(item)
    } else {
      let workspace = archived[target - items.count - 1]
      revealRequest.workspaceID = workspace.id
      selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
    }
  }

  func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    list.routableChat(in: tab, serverId: serverId)
  }

  private func apply(_ route: WorkspaceSelectionRoute?) {
    switch route {
    case let .session(serverId, id):
      selection = .session(serverId: serverId, id: id)
    case let .workspace(serverId, id):
      selection = .workspace(serverId: serverId, id: id)
    case nil:
      break
    }
  }

  func addTab(in item: SidebarWorkspaceListItem) {
    let workspace = item.workspace
    store?.newCenterTabRequest = NewCenterTabRequest(workspaceId: workspace.id)
    if !routesSelectedSession(workspace) {
      activateWorkspace(item)
    }
  }

  func archiveSelectedWorkspace() {
    let workspaceId: UUID? =
      switch selection {
      case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
      case let .workspace(_, id): id
      case .archivedWorkspace, .bot, .newChat, .none: nil
      }
    guard let workspace = workspaceId.flatMap({ environment.workspaces.workspace(id: $0) }),
      !workspace.isArchived
    else { return }
    archiveWorkspace(workspace)
  }

  private func archiveWorkspace(_ workspace: Workspace) {
    let selectionLeaves = routesSelectedSession(workspace)
    environment.archiveWorkspace(workspace)
    pinnedWorkspaceIDs.removeAll { $0 == workspace.id.uuidString }
    if selectionLeaves {
      selectNextChat(serverId: workspace.serverId, leaving: workspace.id)
    }
  }

}

extension ProjectListModel {
  func routableChat(in tab: WorkspaceTab, serverId: String) -> ChatSession? {
    let selected = tab.root.group(id: tab.activeLeafId)?.selectedPane.map { [$0] } ?? []
    let panes = selected + tab.root.allGroups.flatMap(\.state.panes)
    for pane in panes where pane.kind == .chat {
      guard let id = pane.chatSessionId, let session = session(id, serverId: serverId) else { continue }
      return session
    }
    return nil
  }
}
