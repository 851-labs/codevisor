import CodevisorCore
import SwiftUI

struct SessionRouteView: View {
  @Environment(AppEnvironment.self) private var environment
  let store: SessionStore
  let serverId: String
  let sessionId: UUID
  let onFocusedChatChanged: (UUID) -> Void
  let onDisposition: (WorkspaceRouteDisposition) -> Void
  var onShownElsewhere: (ChatSession) -> Void = { _ in }

  private struct DispositionKey: Equatable {
    let hasSession: Bool
    let workspaceId: UUID?
    let generation: UInt64?
  }

  var body: some View {
    let session = environment.projectList.session(sessionId, serverId: serverId)
    let workspaceId = environment.workspaces.workspaceId(forSession: sessionId)
    let entry = workspaceId.map { environment.navigationStore.workspaceEntries.entry($0) }
    Group {
      if let session, store.guestHost(of: session) != nil {
        Color.clear.task(id: session.id) { onShownElsewhere(session) }
      } else if let session, let project = project(for: session) {
        let workspace = entry?.workspace ?? store.workspace(for: session, project: project)
        let controller = store.controller(for: session, project: project)
        SessionContainerView(
          mount: .chat(session, workspace),
          project: project,
          store: store,
          onFocusedChatChanged: onFocusedChatChanged
        )
        .id(workspace.id)
        .task(id: SessionStore.SessionKey(session)) {
          store.noteAccess(SessionStore.SessionKey(session))
        }
        .onChange(of: session, initial: true) { _, updatedSession in
          store.reconcile(controller, for: updatedSession, project: project)
        }
        .onChange(of: project) { _, updatedProject in
          store.reconcile(controller, for: session, project: updatedProject)
        }
      } else {
        ContentUnavailableView(
          "Chat Unavailable",
          systemImage: "bubble.left.and.exclamationmark.bubble.right",
          description: Text("This chat is no longer available on its machine.")
        )
      }
    }
    .onChange(
      of: DispositionKey(hasSession: session != nil, workspaceId: workspaceId, generation: entry?.generation),
      initial: true
    ) { _, _ in
      onDisposition(
        environment.workspaceSync.routeDisposition(
          sessionId: sessionId, serverId: serverId, preservingSelectedPane: true))
    }
  }

  private func project(for session: ChatSession) -> Project? {
    environment.projectList.projects.first {
      $0.serverId == session.serverId && $0.id == session.projectId
    }
  }
}

struct WorkspaceRouteView: View {
  @Environment(AppEnvironment.self) private var environment
  let store: SessionStore
  let serverId: String
  let workspaceId: UUID
  let onFocusedChatChanged: (UUID) -> Void
  let onMoved: (Workspace) -> Void

  private struct Place: Equatable {
    let machineId: String
    let isArchived: Bool
  }

  var body: some View {
    let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace
    content(workspace)
      .onChange(
        of: workspace.map { Place(machineId: $0.serverId, isArchived: $0.isArchived) }, initial: true
      ) { _, place in
        guard let workspace, let place, place != Place(machineId: serverId, isArchived: false) else { return }
        onMoved(workspace)
      }
  }

  @ViewBuilder
  private func content(_ workspace: Workspace?) -> some View {
    if let workspace, workspace.serverId == serverId, workspace.isRestoring {
      RestoringWorkspacePane(workspace: workspace)
        .navigationTitle(SidebarWorkspaceRowLabel.title(for: workspace.name))
    } else if let workspace,
      workspace.serverId == serverId,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == serverId && $0.id == workspace.projectId
      })
    {
      SessionContainerView(
        mount: .workspace(workspace),
        project: project,
        store: store,
        onFocusedChatChanged: onFocusedChatChanged
      )
      .id(workspaceId)
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "rectangle.on.rectangle.slash",
        description: Text("This workspace is no longer available on its machine.")
      )
    }
  }
}
