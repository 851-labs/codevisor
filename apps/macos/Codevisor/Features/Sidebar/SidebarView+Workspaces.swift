import SwiftUI
import CodevisorCore
import CodevisorUI

extension SidebarView {
  var rowContent: SidebarRowContent {
    SidebarRowContent(environment: environment, store: store, grouping: grouping, rowDetails: rowDetails)
  }

  var rowCommands: WorkspaceRowCommands {
    WorkspaceRowCommands(
      environment: environment,
      pinnedIDs: $pinnedWorkspaceIDs,
      rename: { renamingWorkspace = $0 },
      newSection: { sectionPrompt = .create(moving: $0.id) },
      willArchive: { moveSelection(awayFrom: $0) }
    )
  }

  var rowActions: SidebarWorkspaceSection.Actions {
    SidebarWorkspaceSection.Actions(
      activate: { activateWorkspace($0, tabId: $0.workspace.mainTab.id) },
      commands: rowCommands
    )
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
      case let .workspace(item, .pinned), let .workspace(item, .custom), let .workspace(item, .group):
        active.append(item)
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

  var navigator: SidebarWorkspaceNavigator {
    SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection)
  }

  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    navigator.routesSelectedSession(workspace)
  }

  func activateWorkspace(_ item: SidebarWorkspaceListItem, tabId: UUID? = nil) {
    navigator.activate(item, tabId: tabId)
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
    rowCommands.archive(workspace)
  }

  var activeWorkspaceActions: ActiveWorkspaceActions? {
    guard let workspace = selectedActiveWorkspace else { return nil }

    let id = workspace.id
    return ActiveWorkspaceActions(
      name: SidebarWorkspaceRowLabel.title(for: workspace.name), pin: activePin(for: workspace),
      rename: { if let current = currentActiveWorkspace(id) { rowCommands.rename(current) } },
      archive: { if let current = currentActiveWorkspace(id) { rowCommands.archive(current) } })
  }

  private func activePin(for workspace: Workspace) -> WorkspacePin? {
    let item = environment.navigationStore.workspaceEntries.sidebar.first { $0.id == workspace.id }
    guard item.map(SidebarPins.canPin) ?? true else { return nil }

    let id = workspace.id
    return WorkspacePin(isPinned: isPinned(workspace)) {
      if let current = currentActiveWorkspace(id) { rowCommands.togglePin(current) }
    }
  }

  private func currentActiveWorkspace(_ id: UUID) -> Workspace? {
    environment.workspaces.workspace(id: id).flatMap { $0.isArchived ? nil : $0 }
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
