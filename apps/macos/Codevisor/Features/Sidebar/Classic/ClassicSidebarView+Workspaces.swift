import SwiftUI
import CodevisorCore

extension ClassicSidebarView {
  func workspaceSection(_ item: SidebarWorkspaceListItem) -> some View {
    let id = item.workspace.id
    return VStack(alignment: .leading, spacing: 1) {
      workspaceHeader(item)
        .opacity(draggingID == id ? 0.4 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named(Self.reorderSpace))
        } action: { frame in
          recordWorkspaceHeaderFrame(frame, for: id)
        }
        .gesture(reorderGesture(for: .workspace(id)))

      workspaceTabRows(item)
    }
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .named(Self.reorderSpace))
    } action: { frame in
      recordWorkspaceSectionFrame(frame, for: id)
    }
    .onDisappear { forgetWorkspaceGeometry(for: id) }
  }

  func machineName(forServer serverId: String) -> String? {
    let machine = environment.machines.machine(for: serverId)
    return machine.map { $0.isLocal ? "This Mac" : $0.name }
  }

  private func workspaceHeader(_ item: SidebarWorkspaceListItem) -> some View {
    SidebarWorkspaceHeader(
      name: item.workspace.name,
      machineName: machineName(forServer: item.workspace.serverId),
      isReordering: isReordering,
      onArchive: { archiveWorkspace(item.workspace) },
      onRename: {
        workspaceRenameTitle = item.workspace.name
        renamingWorkspace = item.workspace
      },
      onNewTab: { addTab(in: item) }
    )
  }

  func routesSelectedSession(_ workspace: Workspace) -> Bool {
    switch selection {
    case let .session(serverId, sessionId):
      guard serverId == workspace.serverId else { return false }
      return environment.workspaces.workspaceId(forSession: sessionId) == workspace.id
    case let .workspace(serverId, id):
      return serverId == workspace.serverId && id == workspace.id
    case .archivedWorkspace, .newChat, .none:
      return false
    }
  }

  private func archiveWorkspace(_ workspace: Workspace) {
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
      selectNextChat(serverId: workspace.serverId)
    }
  }

}
