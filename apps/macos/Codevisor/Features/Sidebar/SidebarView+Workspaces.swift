import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

extension SidebarView {
  /// Existing chats gain owning workspaces lazily; entering either
  /// workspace-based mode sweeps the visible sessions so the list is
  /// complete. Idempotent and cheap after the first pass (indexed lookups).
  func backfillWorkspaces() {
    guard organization != .compact else { return }
    for item in chronologicalSessions {
      _ = environment.workspaces.ensureWorkspace(
        for: WorkspaceSessionSeed(
          sessionId: item.session.id,
          initialName: item.session.worktreeName ?? item.project.name,
          serverId: item.session.serverId,
          projectId: item.project.id,
          rootDirectory: item.session.cwd ?? item.project.folderURL.path
        ),
        legacyGroups: environment.paneGroups
      )
    }
    workspaceRevision += 1
  }

  /// A newly created chat should be visible immediately in either
  /// workspace-based organization.
  /// Expand only for additions—not ordinary selection changes—so navigating
  /// among existing chats never overrides the user's disclosure choices.
  func revealNewChatWorkspaces(_ sessionIDs: Set<UUID>) {
    guard organization != .compact, !sessionIDs.isEmpty else { return }

    let workspaces = sessionIDs.compactMap { sessionID -> Workspace? in
      guard let workspaceID = environment.workspaces.workspaceId(forSession: sessionID) else {
        return nil
      }
      return environment.workspaces.workspace(id: workspaceID)
    }
    guard !workspaces.isEmpty else { return }

    withAnimation(.snappy(duration: 0.28)) {
      if organization == .byProject {
        expanded.formUnion(workspaces.map(\.projectId))
      } else {
        expandedWorkspaces.formUnion(workspaces.map(\.id))
      }
    }
  }

  @ViewBuilder
  func workspaceFolder(_ item: SidebarWorkspaceListItem) -> some View {
    let isExpanded = expandedWorkspaces.contains(item.workspace.id)
    workspaceRow(
      item,
      isExpanded: isExpanded,
      onToggle: { toggleWorkspace(item.workspace.id) }
    )

    if expandedWorkspaces.contains(item.workspace.id) {
      if isNousMode {
        nousTabRows(item)
      } else {
        if let project = item.project {
          ForEach(item.sessions) { session in
            reorderableChronologicalSessionRow(session, project: project, isNested: true)
              .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
          }
        }
      }
      if item.sessions.isEmpty && !isNousMode {
        Text("No tabs yet")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .padding(
            .leading,
            8 + hierarchyIndent + 24
          )
          .padding(.vertical, 3)
          .transition(.opacity)
      }
    }
  }

  /// One workspace row, either top-level or nested beneath its project.
  /// Nested rows are disclosure-only; top-level workspace rows retain their
  /// primary-chat activation behavior.
  private func workspaceRow(
    _ item: SidebarWorkspaceListItem,
    isExpanded: Bool = false,
    onToggle: (() -> Void)? = nil
  ) -> some View {
    // Top-level workspace organization uses workspace selection styling.
    // A nested workspace is only a disclosure container; its child chat
    // owns selection instead.
    let isSelected = onToggle == nil && routesSelectedSession(item.workspace)
    return SidebarWorkspaceRow(
      item: item,
      store: store,
      isExpanded: isExpanded,
      onToggle: onToggle,
      isSelected: isSelected,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      machineName: environment.machines.fleetMachineName(for: item.workspace.serverId),
      onActivateSession: { activateSession($0) },
      onArchive: { archiveWorkspace(item) },
      onRename: {
        workspaceRenameTitle = item.workspace.name
        renamingWorkspace = item.workspace
      },
      onNewTab: isNousMode ? { addNousTab(in: item) } : nil
    )
  }

  /// Whether the sidebar's selected chat lives in this workspace.
  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    guard case let .session(serverId, sessionId) = selection,
      serverId == workspace.serverId
    else { return false }
    return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
  }

  /// Archives the WORKSPACE (not just a chat): the record is flagged, its
  /// live chats archive with it, and the row leaves the list. Layout is
  /// kept — restoring any of its chats revives the whole workspace.
  private func archiveWorkspace(_ item: SidebarWorkspaceListItem) {
    archiveWorkspace(item.workspace)
  }

  private func archiveWorkspace(_ workspace: Workspace) {
    // Whether the selection lives in this workspace, decided BEFORE the
    // archive (a scratch workspace's discard also drops its session
    // index, which this lookup depends on).
    let selectionLeaves: Bool
    if case let .session(serverId, sessionId) = selection,
      serverId == workspace.serverId,
      environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    {
      selectionLeaves = true
    } else {
      selectionLeaves = false
    }
    environment.archiveWorkspace(workspace)
    if selectionLeaves {
      // Land on the most recent remaining chat; only an empty machine
      // falls through to creating a fresh scratch workspace.
      selectNextChat(excluding: [], serverId: workspace.serverId)
    }
    workspaceRevision += 1
  }

  private func toggleWorkspace(_ id: UUID) {
    withAnimation(.snappy(duration: 0.28)) {
      if expandedWorkspaces.contains(id) {
        expandedWorkspaces.remove(id)
      } else {
        expandedWorkspaces.insert(id)
      }
    }
  }
}
