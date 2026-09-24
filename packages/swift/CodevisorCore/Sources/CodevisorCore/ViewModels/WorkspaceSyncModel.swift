import Foundation
import Observation

/// The shared decision both native navigation surfaces apply when the server
/// changes the workspace or chat currently on screen.
public enum WorkspaceRouteDisposition: Equatable, Sendable {
  case keep
  case selectSession(UUID)
  case dismiss
}

/// The requests navigation surfaces make about workspaces and panes, and the
/// shared routing policy both platforms apply when the server changes what
/// is on screen.
///
/// Workspaces themselves come from `NavigationStore`; this model turns user
/// actions into outbox requests (and layout changes into device-layout
/// writes) and exposes one revision that macOS and iOS navigation observe.
@MainActor
@Observable
public final class WorkspaceSyncModel {
  /// Advances on every navigation rebuild. A wake-up signal for code that
  /// waits for navigation to settle; views observe their workspace's entry
  /// instead, since this changes on every event from every machine.
  public var revision: UInt64 { navigationStore?.revision ?? 0 }

  let repository: any WorkspaceRepository
  let projectList: ProjectListModel
  @ObservationIgnored var navigationStore: NavigationStore?

  public init(repository: any WorkspaceRepository, projectList: ProjectListModel) {
    self.repository = repository
    self.projectList = projectList
  }

  /// Fetches a machine's latest workspaces now (pull to refresh).
  @discardableResult
  public func refreshFromServer(
    serverId: String, client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    guard let navigationStore else { return .failed("No navigation store") }
    return await navigationStore.refresh(machineId: serverId, client: client)
  }

  func enqueue(_ intent: NavigationIntent, serverId: String) {
    navigationStore?.enqueue(intent, machineId: serverId)
  }

  /// macOS routes directly to a session, while iOS carries the workspace in
  /// its path. Resolve both through the same keep/sibling/dismiss policy.
  public func routeDisposition(
    sessionId: UUID,
    serverId: String,
    preservingSelectedPane: Bool = false
  ) -> WorkspaceRouteDisposition {
    guard
      projectList.sessions.contains(where: { $0.id == sessionId && $0.serverId == serverId })
    else { return .dismiss }
    // A chat with no workspace has no archive state anywhere above it, so
    // nothing can dismiss its route.
    guard let workspaceId = repository.workspaceId(forSession: sessionId) else { return .keep }
    return routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: sessionId,
      serverId: serverId,
      preservingSelectedPane: preservingSelectedPane
    )
  }

  public func routeDisposition(
    workspaceId: UUID,
    anchorSessionId: UUID,
    serverId: String,
    preservingSelectedPane: Bool = false
  ) -> WorkspaceRouteDisposition {
    guard let workspace = repository.workspace(id: workspaceId),
      workspace.serverId == serverId,
      !workspace.isArchived
    else { return .dismiss }

    let hasAnchor = projectList.sessions.contains {
      $0.serverId == serverId && $0.id == anchorSessionId
    }
    // macOS may be showing a browser, terminal, or New Tab through a chat
    // route. Closing that hidden routing chat must not replace the page
    // with a sibling chat. The closed route still owns this workspace.
    if preservingSelectedPane, hasAnchor,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId,
      let tab = workspace.selectedCenterTab,
      let pane = tab.root.group(id: tab.activeLeafId)?.selectedPane,
      pane.kind != .chat
    {
      return .keep
    }

    // "Open" is pane presence, not membership: a closed chat keeps belonging
    // to its workspace, and routing must not land on a tab that is gone.
    let active = projectList.sessions.filter { session in
      session.serverId == serverId
        && repository.workspaceId(forSession: session.id) == workspaceId
        && workspace.pane(containingChat: session.id) != nil
    }
    if active.contains(where: { $0.id == anchorSessionId }) { return .keep }
    // The route anchors the workspace, not the visible pane. Closing a
    // chat must not select some other chat's tab when the current layout
    // still has content. Pane closure already chooses the surviving split
    // (or adjacent tab); keep that selection until the user navigates.
    if preservingSelectedPane, hasAnchor, !active.isEmpty,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId,
      workspace.selectedCenterTab?.root.allGroups.contains(where: { group in
        group.state.panes.contains { pane in
          pane.kind != .chat || pane.chatSessionId == nil
            || active.contains(where: { $0.id == pane.chatSessionId })
        }
      }) == true
    {
      return .keep
    }
    if let replacement = active.first { return .selectSession(replacement.id) }
    // No live chat left, but the workspace still shows a terminal or
    // plugin pane: it stays listed (Nous lists those tabs as rows) and a
    // session route is the only way to mount it, so the archived anchor
    // still routed to it keeps the route. A workspace reduced to the New
    // Tab placeholder is dismissed as before.
    if hasAnchor, workspace.hasOpenNonChatContent,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId
    {
      return .keep
    }
    return .dismiss
  }
}
