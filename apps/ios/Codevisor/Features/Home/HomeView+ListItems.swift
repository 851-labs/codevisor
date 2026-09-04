import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// List item construction and status classification for the home
/// navigation list (workspace, project, and loose-session groupings).
extension HomeView {
  /// Workspace containers always follow their persisted manual order. Their
  /// children independently follow the selected agent ordering.
  var workspaceItems: [HomeWorkspaceListItem] {
    _ = workspaceRevision
    _ = environment.workspaceSync.revision
    let sessionRank = Dictionary(
      visibleSessions.enumerated().map { ($0.element.id, $0.offset) },
      uniquingKeysWith: min
    )
    let sessionsById = Dictionary(
      visibleSessions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let items = environment.workspaces.loadAll()
      .filter { !$0.isArchived && currentNavigationMachineIDs.contains($0.serverId) }
      .compactMap { workspace -> HomeWorkspaceListItem? in
        // Honor the repository's grow-only routing index when healing
        // layouts from older iOS builds. A superseded automatic
        // one-chat workspace can remain on disk, but must not produce
        // a duplicate navigation row after its chat moves home.
        let routedSessionIDs = workspace.chatSessionIds.filter {
          environment.workspaces.workspaceId(forSession: $0) == workspace.id
        }
        guard workspace.chatSessionIds.isEmpty || !routedSessionIDs.isEmpty else {
          return nil
        }
        let sessions = routedSessionIDs.compactMap { sessionsById[$0] }
          .sorted {
            (sessionRank[$0.id] ?? Int.max) < (sessionRank[$1.id] ?? Int.max)
          }
        let primary = sessions.first
        let routingSession =
          primary
          ?? visibleSessions.first {
            environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
          }
        let project = projectList.projects.first {
          $0.serverId == workspace.serverId && $0.id == workspace.projectId
        }
        return HomeWorkspaceListItem(
          workspace: workspace,
          sessions: sessions,
          primarySession: routingSession,
          project: project
        )
      }
      .filter {
        showEmptyWorkspaces || !$0.sessions.isEmpty || $0.primarySession != nil
      }
    return manuallyOrdered(
      items,
      ids: preferenceIDs(from: manualWorkspaceOrder),
      id: \.id
    )
  }

  /// One row per repository however many current machines hold a
  /// checkout; each row pools its members' chats in the list order.
  var projectItems: [HomeProjectListItem] {
    let projects = projectList.fleetActiveProjects.filter {
      !$0.isScratch && currentNavigationMachineIDs.contains($0.serverId)
    }
    let items: [HomeProjectListItem] = ProjectGroup.grouping(projects)
      .compactMap { group -> HomeProjectListItem? in
        let sessions = visibleSessions.filter {
          group.contains(serverId: $0.serverId, projectId: $0.projectId)
        }
        guard showEmptyProjects || !sessions.isEmpty else { return nil }
        return HomeProjectListItem(group: group, sessions: sessions)
      }
    return manuallyOrdered(
      items,
      ids: preferenceIDs(from: manualProjectOrder),
      id: \.id
    )
  }

  /// Chats with no project (scratch-backed) or whose project is gone;
  /// by-project mode gathers them under one "No project" row.
  var looseProjectSessions: [ChatSession] {
    let projectKeys = Set(
      projectList.fleetActiveProjects.lazy.filter { !$0.isScratch }.map {
        "\($0.serverId)|\($0.id)"
      }
    )
    return visibleSessions.filter {
      !projectKeys.contains("\($0.serverId)|\($0.projectId)")
    }
  }

  /// Expansion key of the "No project" row — the run-target placeholder id,
  /// which no real project can carry.
  static let noProjectItemID = Project.runTargetPlaceholderID

  var hasNavigationContent: Bool {
    if !visibleSessions.isEmpty { return true }
    switch organization {
    case .compact:
      return false
    case .byWorkspace:
      return !workspaceItems.isEmpty
    case .byProject:
      return !projectItems.isEmpty
    }
  }

  var expandedProjects: Set<UUID> {
    expandedProjectIDs
  }

  var expandedWorkspaces: Set<UUID> {
    persistedIDs(from: expandedWorkspacesRaw)
  }

  /// Sort tier for a chat row. Every state checked here is visible on the
  /// row as `SessionRow.statusIndicator` in the same precedence (error →
  /// attention → in progress → unread, matching the macOS sidebar); keep
  /// the two in sync. If sorting ever consults a state the icon doesn't
  /// show (the macOS sidebar once sorted a spinning chat by its hidden
  /// unread count), opening a chat reorders the list with no visible
  /// state change.
  func priority(for session: ChatSession) -> Int {
    status(for: session).rawValue
  }

  /// Classification follows the agent icon precedence. Raw status ordering
  /// separately lets unread outrank loading when aggregating different
  /// agents into one collapsed workspace indicator.
  func status(for session: ChatSession) -> HomeSessionStatus {
    if session.hasUnreadError { return .error }
    if session.actionRequired || session.pendingPlanApproval { return .actionRequired }
    if ChatControllerCache.shared.isInProgress(session) { return .inProgress }
    if session.unreadCount > 0 { return .unread }
    return .idle
  }

  func status(for item: HomeWorkspaceListItem) -> HomeSessionStatus {
    let sessions =
      item.sessions.isEmpty
      ? item.primarySession.map { [$0] } ?? []
      : item.sessions
    return sessions.map(status(for:)).min() ?? .idle
  }

  func status(for item: HomeProjectListItem) -> HomeSessionStatus {
    item.sessions.map(status(for:)).min() ?? .idle
  }
}
