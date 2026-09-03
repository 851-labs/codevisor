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

  public init(repository: any WorkspaceRepository, projectList: ProjectListModel) {
    self.repository = repository
    self.projectList = projectList
  }

  public func noteLocalMutation() {
    revision &+= 1
  }

  /// Older servers return nil and leave every local workspace untouched.
  public func refreshFromServer(
    serverId: String,
    client: any CodevisorServerClienting
  ) async {
    // Per-server generations: a background machine's refresh must never
    // be gated (or cancelled) by the selected machine's, and vice versa.
    refreshGenerationByServer[serverId, default: 0] &+= 1
    let generation = refreshGenerationByServer[serverId]
    do {
      var records: [ServerWorkspace]
      var paneSnapshot: [ServerWorkspacePane]?
      let usesCoherentSnapshot: Bool
      if let snapshot = try await client.workspaceSnapshot() {
        records = snapshot.workspaces
        paneSnapshot = snapshot.panes
        usesCoherentSnapshot = true
      } else {
        // Rolling-upgrade fallback for servers that expose the two
        // older endpoints but not the atomic snapshot yet.
        async let workspaceRequest = client.listWorkspaces()
        async let paneRequest = client.listWorkspacePanes()
        guard let legacyRecords = try await workspaceRequest else { return }
        records = legacyRecords
        paneSnapshot = try await paneRequest
        usesCoherentSnapshot = false
      }
      guard generation == refreshGenerationByServer[serverId]
      else { return }
      var assignments = projectList.workspaceAssignments(for: serverId)

      // A workspace created before server ownership existed has no
      // server row for panes to reference. Adopt it before backfilling
      // pane identities, and carry the membership we just wrote into
      // this same reconciliation pass instead of waiting for the
      // resulting session events to round-trip.
      let adoption = await adoptLocalWorkspaces(
        records,
        assignments: assignments,
        serverId: serverId,
        client: client
      )
      records = adoption.records
      assignments = adoption.assignments
      guard adoption.canReconcile else { return }

      // Adoption writes a workspace, its pane identities, and session
      // membership after the coherent snapshot above was captured. Do
      // not reconcile that pre-adoption pane list: it can be empty and
      // would evict the live local pane before the server's resulting
      // events arrive. Re-read the atomic snapshot so the repository
      // crosses the ownership boundary in one coherent commit.
      if adoption.didMutateServer {
        guard generation == refreshGenerationByServer[serverId]
        else { return }
        if usesCoherentSnapshot {
          guard let refreshed = try await client.workspaceSnapshot() else { return }
          records = refreshed.workspaces
          paneSnapshot = refreshed.panes
        } else {
          async let workspaceRequest = client.listWorkspaces()
          async let paneRequest = client.listWorkspacePanes()
          guard let refreshedRecords = try await workspaceRequest,
            let refreshedPanes = try await paneRequest
          else { return }
          records = refreshedRecords
          paneSnapshot = refreshedPanes
        }
      }

      var protectedLocalPaneIds = Set<UUID>()
      let panes: [ServerWorkspacePane]?
      if let paneSnapshot, !usesCoherentSnapshot {
        // Backfill is pane-receipt based rather than one global
        // migration bit. It exists only for rolling upgrades; a
        // current server snapshot is authoritative and hydration
        // never manufactures or uploads panes.
        let backfill = await backfillLocalPanes(
          paneSnapshot,
          workspaceRecords: records,
          assignments: assignments,
          serverId: serverId,
          client: client
        )
        panes = backfill.records
        protectedLocalPaneIds = backfill.protectedIds
      } else if let paneSnapshot {
        panes = paneSnapshot
      } else {
        panes = nil
      }
      guard generation == refreshGenerationByServer[serverId]
      else { return }
      reconcile(
        records,
        paneRecords: panes,
        protectedLocalPaneIds: protectedLocalPaneIds,
        assignments: assignments,
        serverId: serverId
      )
    } catch {
      Log.sync.error(
        "Failed to refresh workspaces from server: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// macOS routes directly to a session, while iOS carries the workspace in
  /// its path. Resolve both through the same keep/sibling/dismiss policy.
  public func routeDisposition(
    sessionId: UUID,
    serverId: String
  ) -> WorkspaceRouteDisposition {
    if sessionsInvalidatedByWorkspaceDeletion[serverId]?.contains(sessionId) == true {
      return .dismiss
    }
    guard
      let session = projectList.sessions.first(where: {
        $0.id == sessionId && $0.serverId == serverId
      })
    else { return .dismiss }
    guard let workspaceId = repository.workspaceId(forSession: sessionId) else {
      return session.isArchived ? .dismiss : .keep
    }
    return routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: sessionId,
      serverId: serverId
    )
  }

  public func routeDisposition(
    workspaceId: UUID,
    anchorSessionId: UUID,
    serverId: String
  ) -> WorkspaceRouteDisposition {
    guard let workspace = repository.workspace(id: workspaceId),
      workspace.serverId == serverId,
      !workspace.isArchived
    else { return .dismiss }

    let active = projectList.sessions.filter { session in
      session.serverId == serverId
        && !session.isArchived
        && repository.workspaceId(forSession: session.id) == workspaceId
    }
    if active.contains(where: { $0.id == anchorSessionId }) { return .keep }
    if let replacement = active.first { return .selectSession(replacement.id) }
    // No live chat left, but the workspace still shows a terminal or
    // plugin pane: it stays listed (Nous lists those tabs as rows) and a
    // session route is the only way to mount it, so the archived anchor
    // still routed to it keeps the route. A workspace reduced to the New
    // Tab placeholder is dismissed as before.
    if workspace.hasOpenNonChatContent,
      repository.workspaceId(forSession: anchorSessionId) == workspaceId
    {
      return .keep
    }
    return .dismiss
  }
}
