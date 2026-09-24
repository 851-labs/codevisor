import Foundation
import Observation

/// The shared decision both native navigation surfaces apply when the server
/// changes the workspace or chat currently on screen.
public enum WorkspaceRouteDisposition: Equatable, Sendable {
  case keep
  case selectSession(UUID)
  case dismiss
}

/// Reconciles server-owned workspace identity/metadata with device-local pane
/// layout. The repository deliberately remains the layout persistence layer;
/// this observable revision is the common invalidation source for macOS and
/// iOS navigation.
@MainActor
@Observable
public final class WorkspaceSyncModel {
  struct PanePublicationKey: Hashable {
    var workspaceId: UUID
    var paneId: UUID
  }

  struct PendingPaneMutation {
    var paneId: UUID
    var workspaceId: UUID
    var client: any CodevisorServerClienting
    var operation: PaneMutationOperation
  }

  enum PaneMutationOperation {
    case upsert(PaneDescriptorState)
    case promoteChat(PaneDescriptorState, ChatSession)
    case close
  }

  public internal(set) var revision: UInt64 = 0

  @ObservationIgnored var workspaceOrderTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored var workspaceRenameTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored var pendingWorkspaceRenames: [UUID: Workspace] = [:]

  let repository: any WorkspaceRepository
  let projectList: ProjectListModel
  @ObservationIgnored var sessionsInvalidatedByWorkspaceDeletion: [String: Set<UUID>] = [:]
  @ObservationIgnored var refreshGenerationByServer: [String: UInt64] = [:]
  @ObservationIgnored var pendingPaneMutations: [PanePublicationKey: [PendingPaneMutation]] = [:]
  @ObservationIgnored var publishingPaneKeys: Set<PanePublicationKey> = []
  /// While a renderer conversion is pending, this desired value is the
  /// local authority. Snapshots containing the earlier placeholder cannot
  /// replace it merely because their HTTP response arrived later.
  @ObservationIgnored var optimisticPaneMutations: [PanePublicationKey: PaneDescriptorState] = [:]
  /// A locally-closed pane stays absent while an older snapshot is in
  /// flight. The tombstone clears only after an authoritative snapshot no
  /// longer contains that id.
  @ObservationIgnored var optimisticPaneDeletions: Set<PanePublicationKey> = []
  @ObservationIgnored var confirmedPaneRevisions: [PanePublicationKey: Int] = [:]

  @ObservationIgnored var onSnapshotRefreshed: ((ServerNavigationSnapshot, String) async -> Void)?

  public init(repository: any WorkspaceRepository, projectList: ProjectListModel) {
    self.repository = repository
    self.projectList = projectList
  }

  public func noteLocalMutation() {
    revision &+= 1
  }

  /// One-time, receipt-backed migration of layouts that predate server ownership.
  /// A failed upload leaves local layout intact and the migration retryable.
  func migrateNavigationSnapshot(
    _ initial: ServerNavigationSnapshot, serverId: String,
    client: any CodevisorServerClienting
  ) async throws -> ServerNavigationSnapshot {
    let key = "persisted-navigation-v1:\(serverId)"
    if repository.hasPerformedMigration(key) { return initial }
    let adoption = await adoptLocalWorkspaces(
      initial.workspaces,
      assignments: projectList.workspaceAssignments(for: serverId), serverId: serverId, client: client)
    guard adoption.canReconcile else { throw CodevisorServerClientError.invalidResponse }
    let panes = await backfillLocalPanes(
      initial.panes, workspaceRecords: adoption.records,
      assignments: adoption.assignments, serverId: serverId, client: client)
    guard panes.protectedIds.isEmpty else { throw CodevisorServerClientError.invalidResponse }
    let changed = adoption.didMutateServer || panes.records.count != initial.panes.count
    let snapshot = changed ? try await client.navigationSnapshot() : initial
    try Task.checkCancellation()
    repository.markMigrationPerformed(key)
    return snapshot
  }

  public func applyNavigationSnapshot(_ snapshot: ServerNavigationSnapshot, serverId: String) {
    refreshGenerationByServer[serverId, default: 0] &+= 1
    reconcile(
      snapshot.workspaces, paneRecords: snapshot.panes,
      protectedLocalPaneIds: [], assignments: projectList.workspaceAssignments(for: serverId),
      serverId: serverId)
  }

  @discardableResult
  public func refreshFromServer(
    serverId: String,
    client: any CodevisorServerClienting
  ) async -> ServerNavigationRefreshResult {
    refreshGenerationByServer[serverId, default: 0] &+= 1
    let generation = refreshGenerationByServer[serverId]
    do {
      let snapshot = try await migrateNavigationSnapshot(
        try await client.navigationSnapshot(), serverId: serverId, client: client)
      guard !Task.isCancelled, generation == refreshGenerationByServer[serverId] else { return .superseded }
      if let onSnapshotRefreshed {
        await onSnapshotRefreshed(snapshot, serverId)
      } else {
        applyNavigationSnapshot(snapshot, serverId: serverId)
      }
      retryWorkspaceOrders(serverId: serverId, client: client)
      return .committed
    } catch {
      return .failed(String(describing: error))
    }
  }

  /// macOS routes directly to a session, while iOS carries the workspace in
  /// its path. Resolve both through the same keep/sibling/dismiss policy.
  public func routeDisposition(
    sessionId: UUID,
    serverId: String,
    preservingSelectedPane: Bool = false
  ) -> WorkspaceRouteDisposition {
    if sessionsInvalidatedByWorkspaceDeletion[serverId]?.contains(sessionId) == true {
      return .dismiss
    }
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
