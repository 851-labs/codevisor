import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var nestedTabs: [UUID: [UUID]] {
    guard store != nil else { return [:] }

    let ids = listedSidebarItems.map(\.id) + [selectedArchivedWorkspaceID].compactMap { $0 }
    return SidebarNestedTabs(environment: environment).tabs(of: ids)
  }

  func selectedRowID(in rows: [SidebarRow]) -> SidebarRowID? {
    guard let workspace = selectedSidebarWorkspace else { return nil }

    let tabRow = SidebarRowID.tab(shownTabId(of: workspace))
    return rows.contains { $0.id == tabRow } ? tabRow : .workspace(workspace.id)
  }

  var selectedSidebarTabID: UUID? {
    selectedSidebarWorkspace.map(shownTabId(of:))
  }

  @ViewBuilder
  func tabRow(_ tabId: UUID, of workspaceID: UUID, isSelected: Bool) -> some View {
    if let store, let workspace = storedWorkspace(workspaceID),
      let tab = workspace.centerTabs.first(where: { $0.id == tabId })
    {
      SidebarTabRow(
        label: WorkspaceTabLabel(tab, in: workspace, environment: environment, store: store),
        isSelected: isSelected,
        isReordering: isReordering,
        onSelect: { selectTab(tabId, in: workspaceID) },
        actions: workspace.isArchived ? nil : tabActions(tabId, in: workspaceID)
      )
    }
  }

  func selectTab(_ tabId: UUID, in workspaceID: UUID) {
    guard let workspace = storedWorkspace(workspaceID) else { return }

    if workspace.isArchived {
      store?.archivedTabSelection[workspaceID] = tabId
      selection = .archivedWorkspace(serverId: workspace.serverId, id: workspaceID)
    } else if let item = activeListItem(workspaceID) {
      activateWorkspace(item, tabId: tabId)
    }
  }

  func storedWorkspace(_ id: UUID) -> Workspace? {
    environment.navigationStore.workspaceEntries.entry(id).workspace
  }

  private func tabActions(_ tabId: UUID, in workspaceID: UUID) -> SidebarTabRow.Actions {
    SidebarTabRow.Actions(
      close: { closeTab(tabId, in: workspaceID) },
      keep: { environment.workspaceSync.keepTab(workspaceId: workspaceID, tabId: tabId) }
    )
  }

  private func closeTab(_ tabId: UUID, in workspaceID: UUID) {
    guard let item = activeListItem(workspaceID) else { return }

    store?.closeCenterTabRequest = CloseCenterTabRequest(workspaceId: workspaceID, tabId: tabId)
    if !routesSelectedSession(item.workspace) { activateWorkspace(item) }
  }

  private func activeListItem(_ workspaceID: UUID) -> SidebarWorkspaceListItem? {
    listedSidebarItems.first { $0.id == workspaceID }.flatMap(listItem(for:))
  }

  private var selectedArchivedWorkspaceID: UUID? {
    guard case let .archivedWorkspace(_, id) = selection else { return nil }
    return id
  }

  private var selectedSidebarWorkspace: Workspace? {
    let route: (serverId: String, id: UUID)? =
      switch selection {
      case let .archivedWorkspace(serverId, id): (serverId, id)
      default: routedWorkspace
      }
    guard let route, let workspace = storedWorkspace(route.id), workspace.serverId == route.serverId else { return nil }
    return workspace
  }

  private func shownTabId(of workspace: Workspace) -> UUID {
    guard workspace.isArchived else { return workspace.selectedCenterTabId }
    return store?.archivedTabSelection[workspace.id] ?? workspace.selectedCenterTabId
  }
}

@MainActor
struct SidebarNestedTabs {
  let environment: AppEnvironment

  func tabs(of workspaceIDs: [UUID]) -> [UUID: [UUID]] {
    var tabs: [UUID: [UUID]] = [:]
    for id in workspaceIDs {
      guard let workspace = environment.navigationStore.workspaceEntries.entry(id).workspace, nestsTabs(workspace)
      else { continue }
      tabs[id] = AgentChatTabs.listedTabIds(of: workspace, sessions: environment.projectList)
    }
    return tabs
  }

  private func nestsTabs(_ workspace: Workspace) -> Bool {
    workspace.centerTabs.count > 1 && !WorkspaceLayoutPolicy.isTabless(workspace, environment: environment)
  }
}
