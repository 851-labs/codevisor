import CodevisorCore
import SwiftUI

/// The detail for a chat route. A view of its own so the chat, its workspace
/// entry and the route policy are observed here and not by `RootView`: a tab
/// click re-evaluates this small body, never the window's root.
struct SessionRouteView: View {
  @Environment(AppEnvironment.self) private var environment
  let store: SessionStore
  let serverId: String
  let sessionId: UUID
  let onFocusedChatChanged: (UUID) -> Void
  /// The shared keep/sibling/dismiss policy's answer whenever the route's
  /// chat or workspace changes.
  let onDisposition: (WorkspaceRouteDisposition) -> Void

  /// What the route policy depends on, cheap to compare: the chat's presence
  /// and its workspace's identity and generation.
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
      if let session, let project = project(for: session) {
        // The mount's workspace is chosen here, once per route: the entry's
        // live value when the chat has one, else the store resolves (and for
        // a brand-new chat creates) it.
        let workspace = entry?.workspace ?? store.workspace(for: session, project: project)
        let controller = store.controller(for: session, project: project)
        SessionContainerView(
          mount: .chat(session, controller, workspace),
          project: project,
          store: store,
          onFocusedChatChanged: onFocusedChatChanged
        )
        .id("\(session.serverId):\(workspace.id.uuidString)")
        // Recency bookkeeping (and the eviction it can trigger) runs after
        // the render that shows the chat, never inside it.
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
    // A server refresh can invalidate the route from another device. Apply
    // the shared sibling-or-dismiss policy even though the archived session
    // remains in the local model for the archive section.
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

/// A workspace shown without a chat: the same container, mounted on the
/// workspace itself. Its panes, splits, toolbar and New Tab page are the
/// shared ones; nothing here creates a session, a worktree or an agent.
struct WorkspaceRouteView: View {
  @Environment(AppEnvironment.self) private var environment
  let store: SessionStore
  let serverId: String
  let workspaceId: UUID
  let onFocusedChatChanged: (UUID) -> Void

  var body: some View {
    if let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace,
      workspace.serverId == serverId,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == serverId && $0.id == workspace.projectId
      })
    {
      SessionContainerView(
        mount: .workspace(workspace),
        project: project,
        store: store,
        // The moment a chat exists in this workspace (New Tab → New Chat), the
        // selection moves to it: the container remounts as `.chat`, which is
        // what upgrades the cached leaf group and restores chat affordances.
        onFocusedChatChanged: onFocusedChatChanged
      )
      .id("\(serverId):\(workspaceId.uuidString)")
    } else {
      ContentUnavailableView(
        "Workspace Unavailable",
        systemImage: "rectangle.on.rectangle.slash",
        description: Text("This workspace is no longer available on its machine.")
      )
    }
  }
}
