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

  private var shownWorkspaceItems: (active: [WorkspaceSidebarItem], archived: [WorkspaceSidebarItem]) {
    var active: [WorkspaceSidebarItem] = []
    var archived: [WorkspaceSidebarItem] = []
    for row in sidebarRows {
      switch row.kind {
      case let .workspace(item, .archived): archived.append(item)
      case let .workspace(item, .pinned), let .workspace(item, .group): active.append(item)
      default: continue
      }
    }
    return (active, archived)
  }

  var gitLookupRefreshKey: SidebarGitLookups.RefreshKey? {
    guard store != nil else { return nil }
    return SidebarGitLookups.refreshKey(
      details: rowDetails, workspaceIds: listedSidebarItems.map(\.id),
      archivedWorkspaceIds: shownWorkspaceItems.archived.map(\.id))
  }

  func refreshGitLookups() {
    let shown = shownWorkspaceItems
    let entries = environment.navigationStore.workspaceEntries
    store?.gitLookups.refresh(
      active: shown.active.compactMap(listItem(for:)).map(\.workspace),
      archived: shown.archived.compactMap { entries.entry($0.id).workspace },
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

  var selectedActiveWorkspace: Workspace? {
    let workspaceId: UUID? =
      switch selection {
      case let .session(_, sessionId): environment.workspaces.workspaceId(forSession: sessionId)
      case let .workspace(_, id): id
      case .archivedWorkspace, .bot, .newChat, .none: nil
      }
    guard let workspace = workspaceId.flatMap({ environment.workspaces.workspace(id: $0) }),
      !workspace.isArchived
    else { return nil }
    return workspace
  }

  func archiveSelectedWorkspace() {
    guard let workspace = selectedActiveWorkspace else { return }
    archiveWorkspace(workspace)
  }

  var activeWorkspaceActions: ActiveWorkspaceActions? {
    guard let workspace = selectedActiveWorkspace else { return nil }

    let id = workspace.id
    return ActiveWorkspaceActions(
      name: SidebarWorkspaceRowLabel.title(for: workspace.name), isPinned: isPinned(workspace),
      rename: { if let current = currentActiveWorkspace(id) { rowActions.rename(current) } },
      togglePin: { if let current = currentActiveWorkspace(id) { togglePin(current) } },
      archive: { if let current = currentActiveWorkspace(id) { archiveWorkspace(current) } })
  }

  private func currentActiveWorkspace(_ id: UUID) -> Workspace? {
    environment.workspaces.workspace(id: id).flatMap { $0.isArchived ? nil : $0 }
  }

  private func archiveWorkspace(_ workspace: Workspace) {
    moveSelection(awayFrom: workspace)
    environment.archiveWorkspace(workspace)
    pinnedWorkspaceIDs.removeAll { $0 == workspace.id.uuidString }
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
