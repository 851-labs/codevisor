import CodevisorCore
import CodevisorUI
import SwiftUI

/// Builds the sidebar's workspace sections from the fleet and answers the
/// rows' requests: opening, closing, renaming, and adding tabs.
extension HomeView {
  /// Active chats from machines with a current snapshot. Cached chats stay
  /// hidden until their machine answers.
  var activeSessions: [ChatSession] {
    projectList.sessions.filter {
      !$0.isArchived && currentNavigationMachineIDs.contains($0.serverId)
    }
  }

  /// Workspaces enter newest-first; the saved manual order then owns the
  /// list, so adding or closing tabs never changes a workspace's rank.
  var sidebarSections: [HomeSidebarSection] {
    // Repository writes are not observable; local and remote layout
    // writes invalidate these tokens so the sidebar re-reads the tabs.
    _ = workspaceRevision
    _ = environment.workspaceSync.revision
    let sessionsByKey = Dictionary(
      projectList.sessions.map { (Self.sessionKey($0.serverId, $0.id), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let workspaces = environment.workspaces.loadAll()
      .filter { !$0.isArchived && currentNavigationMachineIDs.contains($0.serverId) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
    let sections = workspaces.compactMap { workspace -> HomeSidebarSection? in
      let routedIDs = workspace.chatSessionIds.filter {
        environment.workspaces.workspaceId(forSession: $0) == workspace.id
      }
      // Suppress superseded automatic workspaces whose chats all moved
      // elsewhere. Empty workspaces have no chat ids and remain visible.
      guard workspace.chatSessionIds.isEmpty || !routedIDs.isEmpty else { return nil }
      // A terminal-only workspace still mounts through an archived chat
      // retained in the session index after its chat tab was closed.
      let anchor =
        routedIDs.lazy
        .compactMap { sessionsByKey[Self.sessionKey(workspace.serverId, $0)] }
        .first { !$0.isArchived }
        ?? projectList.sessions.first {
          $0.serverId == workspace.serverId
            && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
        }
      guard let anchor else { return nil }
      let rows = sidebarRows(for: workspace, sessionsByKey: sessionsByKey)
      return HomeSidebarSection(
        id: workspace.id,
        serverId: workspace.serverId,
        name: workspace.name,
        machineName: machines.fleetMachineName(for: workspace.serverId),
        anchorSessionId: anchor.id,
        status: rows.map(\.status).min() ?? .idle,
        rows: rows
      )
    }
    return manuallyOrdered(
      sections,
      ids: preferenceIDs(from: manualWorkspaceOrder),
      id: \.id
    )
  }

  static func sessionKey(_ serverId: String, _ id: UUID) -> String {
    "\(serverId)|\(id.uuidString)"
  }

  /// Every pane of every center tab, then the bottom panel's — the same
  /// flat order the workspace's tab grid shows on this device.
  private func sidebarRows(
    for workspace: Workspace,
    sessionsByKey: [String: ChatSession]
  ) -> [HomeSidebarTabRow] {
    var seen: Set<UUID> = []
    var rows: [HomeSidebarTabRow] = []
    func append(_ pane: PaneDescriptorState, in tab: WorkspaceTab?) {
      guard seen.insert(pane.id).inserted else { return }
      let chat =
        pane.kind == .chat
        ? pane.chatSessionId.flatMap { sessionsByKey[Self.sessionKey(workspace.serverId, $0)] }
        : nil
      // A chat archived elsewhere may linger in the layout until sync
      // catches up; it is not an open tab.
      if let chat, chat.isArchived { return }
      rows.append(
        HomeSidebarTabRow(
          id: pane.id,
          title: tab?.customTitle ?? paneTitle(pane, chat: chat),
          icon: paneIcon(pane, chat: chat),
          status: chat.map(status(for:)) ?? .idle,
          chatSessionId: chat?.id,
          renamableTabId: tab?.id
        )
      )
    }
    for tab in workspace.centerTabs {
      let groups = tab.root.allGroups
      let isSinglePane = groups.count == 1 && groups[0].state.panes.count == 1
      for group in groups {
        for pane in group.state.panes {
          append(pane, in: isSinglePane ? tab : nil)
        }
      }
    }
    for pane in workspace.bottomGroup.panes {
      append(pane, in: nil)
    }
    return rows
  }

  private func paneTitle(_ pane: PaneDescriptorState, chat: ChatSession?) -> String {
    switch pane.kind {
    case .chat:
      let title = chat?.title ?? pane.name
      return title.isEmpty ? "New Chat" : title
    case .newTab:
      return "New Tab"
    case .browser:
      return BrowserPaneCache.shared.localTitle(paneId: pane.id) ?? pane.name
    case .terminal, .plugin, .document:
      return pane.name
    }
  }

  private func paneIcon(_ pane: PaneDescriptorState, chat: ChatSession?) -> HomeSidebarTabRow.Icon {
    switch pane.kind {
    case .chat:
      .chat(
        harnessId: chat?.harnessId ?? "",
        fallbackSymbolName: chat.map(harnessSymbol(for:)) ?? "text.bubble"
      )
    case .terminal:
      .terminal(isAgentOwned: pane.attachOnly)
    case .browser:
      .browser(favicon: BrowserPaneCache.shared.favicon(paneId: pane.id))
    case .plugin:
      .plugin(pluginId: pane.pluginId ?? "", paneType: pane.pluginPaneType)
    case .document:
      .document
    case .newTab:
      .newTab
    }
  }

  /// Classification follows the status-icon precedence (error → attention
  /// → in progress → unread), the same order the macOS sidebar uses.
  func status(for session: ChatSession) -> HomeSessionStatus {
    if session.hasUnreadError { return .error }
    if session.actionRequired || session.pendingPlanApproval { return .actionRequired }
    if ChatControllerCache.shared.isInProgress(session) { return .inProgress }
    if session.unreadCount > 0 { return .unread }
    return .idle
  }

  // MARK: - Actions

  var sidebarActions: HomeSidebarActions {
    HomeSidebarActions(
      open: { row, section in openSidebarRow(row, in: section) },
      close: { row, section in closeSidebarRow(row, in: section) },
      rename: { row, section in
        guard let tabId = row.renamableTabId else { return }
        tabRenameTitle = row.title
        renamingTab = HomeTabRenameRequest(workspaceId: section.id, tabId: tabId)
      },
      newTab: { section in addSidebarTab(in: section) },
      renameWorkspace: { section in
        guard let workspace = environment.workspaces.workspace(id: section.id) else { return }
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      archiveWorkspace: { section in
        guard let workspace = environment.workspaces.workspace(id: section.id) else { return }
        environment.archiveWorkspace(workspace)
        bumpWorkspaceRevision()
      },
      reorder: { ids in commitWorkspaceOrder(ids) }
    )
  }

  /// Chat rows open their chat like any chat route; other tabs mount the
  /// workspace through its anchor chat and name the pane to show.
  private func openSidebarRow(_ row: HomeSidebarTabRow, in section: HomeSidebarSection) {
    if let chatId = row.chatSessionId,
      let session = projectList.sessions.first(where: {
        $0.serverId == section.serverId && $0.id == chatId
      })
    {
      openChat(session)
      return
    }
    IOSNavigationDiagnostics.record(
      "home.openPane",
      "workspace=\(shortID(section.id)) pane=\(shortID(row.id)) pathBefore=\(navigationPathSummary(path))"
    )
    path.append(
      .workspace(
        serverId: section.serverId,
        workspaceId: section.id,
        anchorSessionId: section.anchorSessionId,
        preferredChatSessionId: nil,
        preferredPaneId: row.id
      )
    )
  }

  /// A background close, without mounting the workspace. Chats archive
  /// (which closes their pane locally and on the server); other panes take
  /// the same last-pane-becomes-New-Tab path the workspace screen uses.
  private func closeSidebarRow(_ row: HomeSidebarTabRow, in section: HomeSidebarSection) {
    if let chatId = row.chatSessionId,
      let session = projectList.sessions.first(where: {
        $0.serverId == section.serverId && $0.id == chatId
      })
    {
      environment.archiveSession(session)
    } else if let workspace = environment.workspaces.workspace(id: section.id) {
      var state = WorkspaceScreen.compactPaneState(from: workspace)
      let replacement: PaneDescriptorState?
      if state.panes.count == 1 {
        replacement = state.replacePaneWithNewTab(id: row.id)
        guard replacement != nil else { return }
      } else {
        replacement = nil
        guard state.closePane(id: row.id) != nil else { return }
      }
      var updated = workspace
      WorkspaceScreen.applyCompactPaneState(state, to: &updated)
      environment.workspaces.save(updated)
      environment.workspaceSync.noteLocalMutation()
      environment.workspaceSync.deletePane(
        id: row.id,
        workspaceId: workspace.id,
        optimisticReplacement: replacement,
        client: environment.machines.client(for: section.serverId)
      )
    }
    if case .plugin = row.icon { PluginPaneCache.shared.remove(paneId: row.id) }
    if case .browser = row.icon { BrowserPaneCache.shared.remove(paneId: row.id) }
    bumpWorkspaceRevision()
  }

  /// Adds a New Tab page to the workspace and opens it there.
  private func addSidebarTab(in section: HomeSidebarSection) {
    guard var workspace = environment.workspaces.workspace(id: section.id) else { return }
    var state = WorkspaceScreen.compactPaneState(from: workspace)
    let pane = state.addNewTabPane()
    WorkspaceScreen.applyCompactPaneState(state, to: &workspace)
    environment.workspaces.save(workspace)
    environment.workspaceSync.noteLocalMutation()
    environment.workspaceSync.publishPane(
      pane,
      workspaceId: workspace.id,
      client: environment.machines.client(for: section.serverId)
    )
    bumpWorkspaceRevision()
    path.append(
      .workspace(
        serverId: section.serverId,
        workspaceId: section.id,
        anchorSessionId: section.anchorSessionId,
        preferredChatSessionId: nil,
        preferredPaneId: pane.id
      )
    )
  }

  /// A rename is a plain layout write (no pane machinery).
  func renameSidebarTab(_ request: HomeTabRenameRequest, to title: String) {
    guard var workspace = environment.workspaces.workspace(id: request.workspaceId),
      let index = workspace.centerTabs.firstIndex(where: { $0.id == request.tabId })
    else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.isEmpty ? nil : trimmed
    guard workspace.centerTabs[index].customTitle != normalized else { return }
    workspace.centerTabs[index].customTitle = normalized
    environment.workspaces.save(workspace)
    bumpWorkspaceRevision()
  }

  func renameWorkspace(_ renamed: Workspace) {
    environment.workspaces.save(renamed)
    bumpWorkspaceRevision()
  }

  /// Re-reads the non-observable repository, animating the resulting
  /// row reflow.
  func bumpWorkspaceRevision() {
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      workspaceRevision += 1
    }
  }

  /// Persists a drag-to-reorder drop. Only the visible workspaces move;
  /// ranks saved for hidden or archived ones are kept.
  func commitWorkspaceOrder(_ ids: [UUID]) {
    manualWorkspaceOrder = mergedPreferenceOrder(
      visibleIDs: ids,
      existingRawValue: manualWorkspaceOrder
    )
  }
}
