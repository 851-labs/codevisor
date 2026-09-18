import SwiftUI
import CodevisorCore

extension SidebarView {
  /// Every active chat with the workspace the server assigns it, when
  /// known. A change here — a chat arriving, leaving, or gaining its
  /// assignment after the fact — is what re-runs the workspace backfill.
  var sessionWorkspaceAssignments: [SidebarSessionListItem.ID: UUID?] {
    var assignmentsByServer: [String: [UUID: UUID]] = [:]
    var result: [SidebarSessionListItem.ID: UUID?] = [:]
    for item in activeSessionItems {
      let serverId = item.session.serverId
      if assignmentsByServer[serverId] == nil {
        assignmentsByServer[serverId] = environment.projectList.workspaceAssignments(for: serverId)
      }
      result[item.id] = assignmentsByServer[serverId]?[item.session.id]
    }
    return result
  }

  /// Existing chats gain owning workspaces lazily. Idempotent and cheap
  /// after the first pass (indexed lookups). The server's assignment rides
  /// along so a chat created elsewhere joins its workspace rather than
  /// minting a sibling.
  func ensureSessionWorkspaces() {
    for item in activeSessionItems {
      let serverId = item.session.serverId
      _ = environment.workspaces.ensureWorkspace(
        for: WorkspaceSessionSeed(
          sessionId: item.session.id,
          initialName: item.session.worktreeName ?? item.project.name,
          serverId: serverId,
          projectId: item.project.id,
          rootDirectory: item.session.cwd ?? item.project.folderURL.path,
          worktreeName: item.session.worktreeName,
          assignedWorkspaceId: environment.projectList.workspaceAssignments(for: serverId)[item.session.id]
        ),
        legacyGroups: environment.paneGroups
      )
    }
    workspaceRevision += 1
  }

  /// One workspace: its header (the reorder handle) over its tab rows.
  /// Both report their frames so a drag can compare the lifted header
  /// against whole sections and land back on the header precisely.
  func workspaceSection(_ item: SidebarWorkspaceListItem) -> some View {
    let id = item.workspace.id
    return VStack(alignment: .leading, spacing: 1) {
      workspaceHeader(item)
        // The lifted row stays dimmed in place while its ghost travels.
        .opacity(draggingWorkspaceID == id ? 0.4 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(Self.reorderSpace))
        } action: { frame in
          recordWorkspaceHeaderFrame(frame, for: id)
        }
        .gesture(workspaceReorderGesture(for: id))

      workspaceTabRows(item)
    }
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(Self.reorderSpace))
    } action: { frame in
      recordWorkspaceSectionFrame(frame, for: id)
    }
    .onDisappear { forgetWorkspaceGeometry(for: id) }
  }

  /// Where the workspace lives. Nil when its machine is unknown — an
  /// unresolved server isn't necessarily this one, so it stays unlabeled.
  func machineName(for item: SidebarWorkspaceListItem) -> String? {
    let machine = environment.machines.machine(for: item.workspace.serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  private func workspaceHeader(_ item: SidebarWorkspaceListItem) -> some View {
    SidebarWorkspaceHeader(
      name: item.workspace.name,
      machineName: machineName(for: item),
      isReordering: isReordering,
      onArchive: { archiveWorkspace(item.workspace) },
      onRename: {
        workspaceRenameTitle = item.workspace.name
        renamingWorkspace = item.workspace
      },
      onNewTab: { addTab(in: item) }
    )
  }

  /// Whether the sidebar's selection is showing this workspace: its selected
  /// chat lives here, or the workspace itself is selected (it has no chat).
  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .newChat, .none:
      return false
    }
  }

  /// Archives the WORKSPACE (not just a chat): the record is flagged, its
  /// live chats archive with it, and the row leaves the list. Layout is
  /// kept — restoring any of its chats revives the whole workspace.
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
      selectNextChat(serverId: workspace.serverId)
    }
    workspaceRevision += 1
  }

}
