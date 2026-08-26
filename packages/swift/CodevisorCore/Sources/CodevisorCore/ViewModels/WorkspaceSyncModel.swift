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
    private struct PanePublicationKey: Hashable {
        var workspaceId: UUID
        var paneId: UUID
    }

    private struct PendingPaneMutation {
        var paneId: UUID
        var workspaceId: UUID
        var client: any CodevisorServerClienting
        var operation: PaneMutationOperation
    }

    private enum PaneMutationOperation {
        case upsert(PaneDescriptorState)
        case promoteChat(PaneDescriptorState, ChatSession)
        case close
    }

    public private(set) var revision: UInt64 = 0

    private let repository: any WorkspaceRepository
    private let projectList: ProjectListModel
    @ObservationIgnored private var sessionsInvalidatedByWorkspaceDeletion: [String: Set<UUID>] = [:]
    @ObservationIgnored private var refreshGenerationByServer: [String: UInt64] = [:]
    @ObservationIgnored private var pendingPaneMutations: [PanePublicationKey: [PendingPaneMutation]] = [:]
    @ObservationIgnored private var publishingPaneKeys: Set<PanePublicationKey> = []
    /// While a renderer conversion is pending, this desired value is the
    /// local authority. Snapshots containing the earlier placeholder cannot
    /// replace it merely because their HTTP response arrived later.
    @ObservationIgnored private var optimisticPaneMutations: [PanePublicationKey: PaneDescriptorState] = [:]
    /// A locally-closed pane stays absent while an older snapshot is in
    /// flight. The tombstone clears only after an authoritative snapshot no
    /// longer contains that id.
    @ObservationIgnored private var optimisticPaneDeletions: Set<PanePublicationKey> = []
    @ObservationIgnored private var confirmedPaneRevisions: [PanePublicationKey: Int] = [:]

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

    /// Publishes content identity only. Selection, tab order, and split
    /// placement remain in the local workspace repository.
    public func publishPane(
        _ pane: PaneDescriptorState,
        workspaceId: UUID,
        client: any CodevisorServerClienting
    ) {
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
        optimisticPaneDeletions.remove(key)
        optimisticPaneMutations[key] = pane
        enqueuePaneMutation(
            PendingPaneMutation(
                paneId: pane.id,
                workspaceId: workspaceId,
                client: client,
                operation: .upsert(pane)
            )
        )
    }

    /// The pane is already a chat in the device-local layout when this is
    /// called. The optimistic barrier is installed synchronously, then the
    /// server converts that exact id and attaches the deferred session as one
    /// observable mutation.
    public func promotePaneToChat(
        _ pane: PaneDescriptorState,
        session: ChatSession,
        workspaceId: UUID,
        client: any CodevisorServerClienting
    ) {
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
        optimisticPaneDeletions.remove(key)
        optimisticPaneMutations[key] = pane
        enqueuePaneMutation(
            PendingPaneMutation(
                paneId: pane.id,
                workspaceId: workspaceId,
                client: client,
                operation: .promoteChat(pane, session)
            )
        )
    }

    private func enqueuePaneMutation(_ mutation: PendingPaneMutation) {
        let key = PanePublicationKey(
            workspaceId: mutation.workspaceId,
            paneId: mutation.paneId
        )
        pendingPaneMutations[key, default: []].append(mutation)
        guard publishingPaneKeys.insert(key).inserted else { return }
        Task { await drainPaneMutations(for: key) }
    }

    private func drainPaneMutations(for key: PanePublicationKey) async {
        defer { publishingPaneKeys.remove(key) }
        // New Tab, its promoted renderer, and its close intentionally share an
        // id. Preserve the exact user-command order so an immediate close can
        // never reach the server before the create it is closing.
        while var queue = pendingPaneMutations[key], !queue.isEmpty {
            let mutation = queue.removeFirst()
            if queue.isEmpty {
                pendingPaneMutations.removeValue(forKey: key)
            } else {
                pendingPaneMutations[key] = queue
            }
            switch mutation.operation {
            case .upsert, .promoteChat:
                await performPanePublication(mutation)
            case .close:
                await performPaneClose(
                    id: mutation.paneId,
                    workspaceId: mutation.workspaceId,
                    client: mutation.client
                )
            }
        }
    }

    private func performPanePublication(_ mutation: PendingPaneMutation) async {
        let pane: PaneDescriptorState
        switch mutation.operation {
        case let .upsert(candidate), let .promoteChat(candidate, _):
            pane = candidate
        case .close:
            return
        }
        let workspaceId = mutation.workspaceId
        let client = mutation.client
        guard let workspace = repository.workspace(id: workspaceId) else { return }
        do {
            guard
                let targetWorkspaceId = try await publishWorkspaceIfNeeded(
                    workspace,
                    client: client
                )
            else { return }
            if case let .promoteChat(_, session) = mutation.operation {
                let candidate = Self.serverPane(
                    from: pane,
                    workspaceId: targetWorkspaceId,
                    createdAt: Date()
                )
                if let promotion = try await client.promoteWorkspacePaneToChat(
                    candidate,
                    session: session
                ) {
                    noteConfirmedRevision(promotion.pane)
                    repository.markMigrationPerformed(
                        Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
                    )
                } else {
                    // Rolling-upgrade fallback. The optimistic barrier still
                    // prevents the intermediate placeholder snapshot from
                    // repainting the initiating client.
                    _ = try await client.upsertSession(session)
                    if let uploaded = try await client.upsertWorkspacePane(candidate) {
                        noteConfirmedRevision(uploaded)
                        repository.markMigrationPerformed(
                            Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
                        )
                    }
                    _ = try await client.upsertSession(session, workspaceId: targetWorkspaceId)
                }
                await refreshFromServer(serverId: workspace.serverId, client: client)
                return
            }
            if pane.kind == .chat,
                let sessionId = pane.chatSessionId,
                let session = projectList.sessions.first(where: {
                    $0.serverId == workspace.serverId && $0.id == sessionId
                })
            {
                // Establish the session without membership first. Publishing
                // the explicit pane then assigning membership prevents the
                // server's legacy membership bridge from briefly synthesizing
                // a second chat pane keyed by the session id.
                _ = try await client.upsertSession(session)
                if let uploaded = try await client.upsertWorkspacePane(
                    Self.serverPane(from: pane, workspaceId: targetWorkspaceId, createdAt: Date())
                ) {
                    noteConfirmedRevision(uploaded)
                    repository.markMigrationPerformed(
                        Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
                    )
                }
                _ = try await client.upsertSession(session, workspaceId: targetWorkspaceId)
                return
            }
            if let uploaded = try await client.upsertWorkspacePane(
                Self.serverPane(from: pane, workspaceId: targetWorkspaceId, createdAt: Date())
            ) {
                noteConfirmedRevision(uploaded)
                repository.markMigrationPerformed(
                    Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
                )
            }
        } catch {
            let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
            if optimisticPaneMutations[key] == pane {
                optimisticPaneMutations.removeValue(forKey: key)
            }
            Log.sync.error(
                "Failed to publish workspace pane \(pane.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func deletePane(
        id: UUID,
        workspaceId: UUID,
        optimisticReplacement: PaneDescriptorState? = nil,
        client: any CodevisorServerClienting
    ) {
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
        if let optimisticReplacement {
            optimisticPaneDeletions.remove(key)
            optimisticPaneMutations[key] = optimisticReplacement
        } else {
            optimisticPaneMutations.removeValue(forKey: key)
            optimisticPaneDeletions.insert(key)
        }
        enqueuePaneMutation(
            PendingPaneMutation(
                paneId: id,
                workspaceId: workspaceId,
                client: client,
                operation: .close
            )
        )
    }

    private func performPaneClose(
        id: UUID,
        workspaceId: UUID,
        client: any CodevisorServerClienting
    ) async {
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
        do {
            let replacement = try await client.closeWorkspacePane(
                workspaceId: workspaceId,
                paneId: id
            )
            if let replacement, let descriptor = Self.descriptor(from: replacement) {
                optimisticPaneDeletions.remove(key)
                optimisticPaneMutations.removeValue(forKey: key)
                noteConfirmedRevision(replacement)
                if var workspace = repository.workspace(id: workspaceId) {
                    if !Self.replacePane(id: id, with: descriptor, in: &workspace) {
                        let state = PaneGroupState(
                            panes: [descriptor], selectedPaneId: descriptor.id, isVisible: true
                        )
                        workspace.centerTabs.append(WorkspaceTab(root: .leaf(state)))
                    }
                    Self.pruneEmptyCenterTabs(in: &workspace)
                    Self.ensureUsableLayout(&workspace)
                    repository.save(workspace)
                    revision &+= 1
                }
            } else {
                optimisticPaneMutations.removeValue(forKey: key)
                confirmedPaneRevisions.removeValue(forKey: key)
                if var workspace = repository.workspace(id: workspaceId),
                    Self.removePane(id: id, from: &workspace)
                {
                    Self.ensureUsableLayout(&workspace)
                    repository.save(workspace)
                    revision &+= 1
                }
            }
        } catch {
            optimisticPaneMutations.removeValue(forKey: key)
            optimisticPaneDeletions.remove(key)
            Log.sync.error(
                "Failed to close workspace pane \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Applies a live delete immediately; the next snapshot catches anything
    /// missed while disconnected.
    public func removePane(id: UUID, workspaceId: UUID, serverId: String) {
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
        optimisticPaneMutations.removeValue(forKey: key)
        optimisticPaneDeletions.remove(key)
        confirmedPaneRevisions.removeValue(forKey: key)
        guard var workspace = repository.workspace(id: workspaceId),
            workspace.serverId == serverId
        else { return }
        guard Self.removePane(id: id, from: &workspace) else { return }
        Self.ensureUsableLayout(&workspace)
        repository.save(workspace)
        revision &+= 1
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
        return .dismiss
    }

    private func reconcile(
        _ records: [ServerWorkspace],
        paneRecords: [ServerWorkspacePane]?,
        protectedLocalPaneIds: Set<UUID>,
        assignments: [UUID: UUID],
        serverId: String
    ) {
        let sessionOrder = Dictionary(
            uniqueKeysWithValues: projectList.sessions
                .filter { $0.serverId == serverId }
                .enumerated()
                .map { ($0.element.id, $0.offset) }
        )
        let sessionsByWorkspace = Dictionary(grouping: assignments.keys) { assignments[$0]! }
            .mapValues { ids in
                ids.sorted { sessionOrder[$0, default: .max] < sessionOrder[$1, default: .max] }
            }

        var changed = false
        var remoteIds = Set<UUID>()

        if !assignments.isEmpty {
            sessionsInvalidatedByWorkspaceDeletion[serverId]?.subtract(assignments.keys)
        }

        for record in records {
            guard let id = UUID(uuidString: record.id),
                let projectId = UUID(uuidString: record.projectId),
                let createdAt = Self.date(from: record.createdAt)
            else {
                Log.sync.error("Dropping unmappable server workspace \(record.id, privacy: .public)")
                continue
            }
            remoteIds.insert(id)
            let sessionIds = sessionsByWorkspace[id] ?? []
            let worktreeName = sessionIds.lazy.compactMap { sessionId in
                self.projectList.sessions.first(where: {
                    $0.id == sessionId && $0.serverId == serverId
                })?.worktreeName
            }.first
            let existing = repository.workspace(id: id)
            let migrationSource =
                existing == nil
                ? sessionIds.lazy.compactMap { sessionId -> Workspace? in
                    guard let oldId = self.repository.workspaceId(forSession: sessionId), oldId != id else {
                        return nil
                    }
                    guard let source = self.repository.workspace(id: oldId),
                        !source.chatSessionIds.isEmpty,
                        source.chatSessionIds.allSatisfy({ assignments[$0] == id })
                    else {
                        return nil
                    }
                    return source
                }.first
                : nil

            var workspace: Workspace
            if let existing {
                workspace = existing
            } else if let source = migrationSource {
                workspace = Workspace(
                    id: id,
                    name: record.hasCustomName ? record.name : source.name,
                    hasCustomName: record.hasCustomName || source.hasCustomName,
                    rootDirectory: record.rootDirectory ?? source.rootDirectory,
                    worktreeName: source.worktreeName ?? worktreeName,
                    serverId: serverId,
                    projectId: projectId,
                    centerTabs: source.centerTabs,
                    selectedCenterTabId: source.selectedCenterTabId,
                    bottomGroup: source.bottomGroup,
                    createdAt: createdAt,
                    isArchived: record.isArchived,
                    isServerSynced: true
                )
            } else {
                workspace = Self.makeWorkspace(
                    id: id,
                    projectId: projectId,
                    serverId: serverId,
                    record: record,
                    createdAt: createdAt,
                    worktreeName: worktreeName,
                    sessionIds: sessionIds,
                    usesPaneRegistry: paneRecords != nil
                )
            }

            // A native-only custom name predating workspace sync must not be
            // erased by the server's generated project/worktree default.
            // Once the server carries an explicit name, it is authoritative.
            if !workspace.hasCustomName || record.hasCustomName {
                workspace.name = record.name
                workspace.hasCustomName = record.hasCustomName
            }
            workspace.rootDirectory = record.rootDirectory ?? workspace.rootDirectory
            workspace.worktreeName = workspace.worktreeName ?? worktreeName
            workspace.isArchived = record.isArchived
            workspace.isServerSynced = true

            if let paneRecords {
                var paneProtection = protectedLocalPaneIds
                let stableRecords = stablePaneSnapshot(
                    paneRecords.filter {
                        $0.workspaceId.caseInsensitiveCompare(record.id) == .orderedSame
                    },
                    workspaceId: id,
                    protectedLocalPaneIds: &paneProtection
                )
                Self.reconcilePanes(
                    in: &workspace,
                    records: stableRecords,
                    protectedLocalPaneIds: paneProtection
                )
            } else {
                for sessionId in sessionIds where workspace.tabId(containingChat: sessionId) == nil {
                    workspace.centerTabs.append(
                        WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId)))
                    )
                }
            }

            if existing != workspace || migrationSource != nil {
                repository.save(workspace)
                changed = true
            }
            if let source = migrationSource, source.id != id {
                repository.delete(id: source.id)
                changed = true
            }
        }

        // Only identities previously confirmed by the server participate in
        // snapshot deletion. Legacy/client-only layouts survive older servers
        // and are adopted once a session publishes their workspace id.
        for workspace in repository.loadAll()
        where
            workspace.serverId == serverId
            && workspace.isServerSynced
            && !remoteIds.contains(workspace.id)
        {
            sessionsInvalidatedByWorkspaceDeletion[serverId, default: []]
                .formUnion(workspace.chatSessionIds)
            repository.delete(id: workspace.id)
            changed = true
        }

        // A legacy automatic workspace can be superseded by multiple
        // authoritative identities. Once every chat routes elsewhere it no
        // longer owns navigation or layout state and can be removed safely.
        for workspace in repository.loadAll()
        where
            workspace.serverId == serverId
            && !workspace.isServerSynced
            && !workspace.chatSessionIds.isEmpty
            && workspace.chatSessionIds.allSatisfy({ sessionId in
                guard let assigned = assignments[sessionId] else { return false }
                return assigned != workspace.id
            })
        {
            repository.delete(id: workspace.id)
            changed = true
        }

        if changed { revision &+= 1 }
    }

    /// Filters a pane snapshot through the optimistic/confirmed revision
    /// barrier. A matching promoted renderer acknowledges the local mutation;
    /// lower revisions and missing pending ids preserve the current local
    /// descriptor instead of causing a visible rollback.
    private func stablePaneSnapshot(
        _ records: [ServerWorkspacePane],
        workspaceId: UUID,
        protectedLocalPaneIds: inout Set<UUID>
    ) -> [ServerWorkspacePane] {
        var stable: [ServerWorkspacePane] = []
        var observedIds = Set<UUID>()
        for record in records {
            guard let paneId = UUID(uuidString: record.id) else {
                stable.append(record)
                continue
            }
            observedIds.insert(paneId)
            let key = PanePublicationKey(workspaceId: workspaceId, paneId: paneId)
            if optimisticPaneDeletions.contains(key) { continue }
            let remoteRevision = record.revision ?? 0
            if remoteRevision < confirmedPaneRevisions[key, default: 0] {
                protectedLocalPaneIds.insert(paneId)
                continue
            }
            if let desired = optimisticPaneMutations[key] {
                if Self.descriptor(from: record) == desired {
                    optimisticPaneMutations.removeValue(forKey: key)
                    confirmedPaneRevisions[key] = max(
                        confirmedPaneRevisions[key, default: 0],
                        remoteRevision
                    )
                    stable.append(record)
                } else {
                    protectedLocalPaneIds.insert(paneId)
                }
                continue
            }
            confirmedPaneRevisions[key] = max(
                confirmedPaneRevisions[key, default: 0],
                remoteRevision
            )
            stable.append(record)
        }
        for (key, _) in optimisticPaneMutations
        where key.workspaceId == workspaceId && !observedIds.contains(key.paneId) {
            protectedLocalPaneIds.insert(key.paneId)
        }
        for key in Array(optimisticPaneDeletions)
        where key.workspaceId == workspaceId && !observedIds.contains(key.paneId) {
            optimisticPaneDeletions.remove(key)
            confirmedPaneRevisions.removeValue(forKey: key)
        }
        return stable
    }

    private func noteConfirmedRevision(_ pane: ServerWorkspacePane) {
        guard let workspaceId = UUID(uuidString: pane.workspaceId),
            let paneId = UUID(uuidString: pane.id)
        else { return }
        let key = PanePublicationKey(workspaceId: workspaceId, paneId: paneId)
        confirmedPaneRevisions[key] = max(
            confirmedPaneRevisions[key, default: 0],
            pane.revision ?? 0
        )
    }

    private struct WorkspaceAdoptionResult {
        var records: [ServerWorkspace]
        var assignments: [UUID: UUID]
        var didMutateServer: Bool
        var canReconcile: Bool
    }

    /// Promotes legacy client-only workspaces into the server registry. If
    /// any chat already points at a server workspace, that identity wins and
    /// unassigned sibling chats join it; otherwise the local workspace id is
    /// claimed. This is what lets two clients with different pre-sync layout
    /// ids converge instead of creating parallel copies of the same workspace.
    private func adoptLocalWorkspaces(
        _ snapshot: [ServerWorkspace],
        assignments initialAssignments: [UUID: UUID],
        serverId: String,
        client: any CodevisorServerClienting
    ) async -> WorkspaceAdoptionResult {
        var records = snapshot
        var assignments = initialAssignments
        var remoteIds = Set(records.compactMap { UUID(uuidString: $0.id) })
        var didMutateServer = false

        for workspace in repository.loadAll()
        where workspace.serverId == serverId && !workspace.isServerSynced {
            let chatIds = workspace.chatSessionIds
            let assignedTargets = Set(chatIds.compactMap { assignments[$0] })
            let targetWorkspaceId: UUID

            if assignedTargets.count == 1,
                let assigned = assignedTargets.first,
                remoteIds.contains(assigned)
            {
                targetWorkspaceId = assigned
            } else if remoteIds.contains(workspace.id) {
                targetWorkspaceId = workspace.id
            } else if assignedTargets.isEmpty {
                do {
                    guard
                        let uploaded = try await client.upsertWorkspace(
                            Self.serverWorkspace(from: workspace)
                        ), let uploadedId = UUID(uuidString: uploaded.id)
                    else { continue }
                    targetWorkspaceId = uploadedId
                    records.removeAll {
                        $0.id.caseInsensitiveCompare(uploaded.id) == .orderedSame
                    }
                    records.append(uploaded)
                    remoteIds.insert(uploadedId)
                    didMutateServer = true
                } catch {
                    Log.sync.error(
                        "Failed to adopt workspace \(workspace.id, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    continue
                }
            } else {
                // Conflicting server memberships require an authoritative
                // snapshot to settle; never guess and merge distinct workspaces.
                continue
            }

            let sessions = chatIds.compactMap { chatId in
                projectList.sessions.first(where: {
                    $0.serverId == serverId && $0.id == chatId
                })
            }

            // A new local workspace owns its pane identities. Publish them
            // before membership invokes the server's compatibility bridge;
            // otherwise the bridge creates a replacement pane keyed by the
            // session id and the native transcript host is torn down.
            if assignedTargets.isEmpty, targetWorkspaceId == workspace.id {
                do {
                    for session in sessions {
                        _ = try await client.upsertSession(session)
                        didMutateServer = true
                    }
                    for localPane in Self.allPanes(in: workspace) {
                        guard
                            try await client.upsertWorkspacePane(
                                Self.serverPane(
                                    from: localPane,
                                    workspaceId: targetWorkspaceId,
                                    createdAt: workspace.createdAt
                                )
                            ) != nil
                        else {
                            throw WorkspaceAdoptionError.panePublicationUnavailable
                        }
                        repository.markMigrationPerformed(
                            Self.panePublicationKey(
                                serverId: workspace.serverId,
                                paneId: localPane.id
                            )
                        )
                        didMutateServer = true
                    }
                } catch {
                    Log.sync.error(
                        "Failed to publish panes while adopting workspace \(workspace.id, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    return WorkspaceAdoptionResult(
                        records: records,
                        assignments: assignments,
                        didMutateServer: didMutateServer,
                        canReconcile: false
                    )
                }
            }

            for session in sessions where assignments[session.id] != targetWorkspaceId {
                do {
                    _ = try await client.upsertSession(
                        session,
                        workspaceId: targetWorkspaceId
                    )
                    assignments[session.id] = targetWorkspaceId
                    didMutateServer = true
                } catch {
                    Log.sync.error(
                        "Failed to adopt chat \(session.id, privacy: .public) into workspace \(targetWorkspaceId, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    return WorkspaceAdoptionResult(
                        records: records,
                        assignments: assignments,
                        didMutateServer: didMutateServer,
                        canReconcile: false
                    )
                }
            }
        }

        return WorkspaceAdoptionResult(
            records: records,
            assignments: assignments,
            didMutateServer: didMutateServer,
            canReconcile: true
        )
    }

    private enum WorkspaceAdoptionError: Error {
        case panePublicationUnavailable
    }

    /// Establishes a server workspace before any pane mutation references it.
    /// On the first adoption it also uploads the complete local pane set, so
    /// the action that creates pane N cannot strand panes 1...(N-1) locally.
    private func publishWorkspaceIfNeeded(
        _ workspace: Workspace,
        client: any CodevisorServerClienting
    ) async throws -> UUID? {
        let assignments = projectList.workspaceAssignments(for: workspace.serverId)
        let assignedTargets = Set(workspace.chatSessionIds.compactMap { assignments[$0] })
        let targetWorkspaceId =
            assignedTargets.count == 1 ? assignedTargets.first! : workspace.id
        let needsAdoption = !workspace.isServerSynced || targetWorkspaceId != workspace.id

        if !workspace.isServerSynced && targetWorkspaceId == workspace.id {
            guard try await client.upsertWorkspace(Self.serverWorkspace(from: workspace)) != nil
            else { return nil }
        }

        if needsAdoption {
            let sessions = workspace.chatSessionIds.compactMap { chatId in
                projectList.sessions.first(where: {
                    $0.serverId == workspace.serverId && $0.id == chatId
                })
            }
            // Pane identity must exist before membership invokes the legacy
            // compatibility bridge; otherwise that bridge briefly creates a
            // second chat pane keyed by the session id.
            for session in sessions {
                _ = try await client.upsertSession(session)
            }
            for localPane in Self.allPanes(in: workspace) {
                if try await client.upsertWorkspacePane(
                    Self.serverPane(
                        from: localPane,
                        workspaceId: targetWorkspaceId,
                        createdAt: workspace.createdAt
                    )
                ) != nil {
                    repository.markMigrationPerformed(
                        Self.panePublicationKey(
                            serverId: workspace.serverId,
                            paneId: localPane.id
                        )
                    )
                }
            }
            for session in sessions {
                _ = try await client.upsertSession(session, workspaceId: targetWorkspaceId)
            }

            if targetWorkspaceId == workspace.id,
                var adopted = repository.workspace(id: workspace.id),
                !adopted.isServerSynced
            {
                adopted.isServerSynced = true
                repository.save(adopted)
                revision &+= 1
            }
        }

        return targetWorkspaceId
    }

    private func backfillLocalPanes(
        _ snapshot: [ServerWorkspacePane],
        workspaceRecords: [ServerWorkspace],
        assignments: [UUID: UUID],
        serverId: String,
        client: any CodevisorServerClienting
    ) async -> (records: [ServerWorkspacePane], protectedIds: Set<UUID>) {
        var records = snapshot
        var ids = Set(snapshot.compactMap { UUID(uuidString: $0.id) })
        var resourceKeys = Set(snapshot.compactMap(Self.resourceKey))
        var protectedIds = Set<UUID>()
        let remoteWorkspaceIds = Set(
            workspaceRecords.compactMap { UUID(uuidString: $0.id) }
        )
        for record in snapshot {
            guard let paneId = UUID(uuidString: record.id) else { continue }
            repository.markMigrationPerformed(
                Self.panePublicationKey(serverId: serverId, paneId: paneId)
            )
        }
        for workspace in repository.loadAll() where workspace.serverId == serverId {
            let assignedTargets = Set(workspace.chatSessionIds.compactMap { assignments[$0] })
            let targetWorkspaceId: UUID?
            if assignedTargets.count == 1 {
                targetWorkspaceId = assignedTargets.first
            } else if remoteWorkspaceIds.contains(workspace.id) {
                targetWorkspaceId = workspace.id
            } else {
                targetWorkspaceId = nil
            }
            guard let targetWorkspaceId, remoteWorkspaceIds.contains(targetWorkspaceId) else {
                continue
            }
            for pane in Self.allPanes(in: workspace) where !ids.contains(pane.id) {
                if repository.hasPerformedMigration(
                    Self.panePublicationKey(serverId: serverId, paneId: pane.id)
                ) {
                    continue
                }
                if let key = Self.resourceKey(pane), resourceKeys.contains(key) {
                    continue
                }
                do {
                    let candidate = Self.serverPane(
                        from: pane,
                        workspaceId: targetWorkspaceId,
                        createdAt: workspace.createdAt
                    )
                    if let uploaded = try await client.upsertWorkspacePane(candidate) {
                        records.append(uploaded)
                        ids.insert(pane.id)
                        if let key = Self.resourceKey(uploaded) { resourceKeys.insert(key) }
                        repository.markMigrationPerformed(
                            Self.panePublicationKey(serverId: serverId, paneId: pane.id)
                        )
                    } else {
                        protectedIds.insert(pane.id)
                    }
                } catch {
                    protectedIds.insert(pane.id)
                    Log.sync.error(
                        "Failed to backfill workspace pane \(pane.id, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        return (records, protectedIds)
    }

    private struct NativePaneMetadata: Codable {
        var attachOnly: Bool
        var ownerChatSessionId: UUID?
    }

    private static func panePublicationKey(serverId: String, paneId: UUID) -> String {
        "workspace-pane-published-v1:\(serverId):\(paneId.uuidString.lowercased())"
    }

    private static func serverWorkspace(from workspace: Workspace) -> ServerWorkspace {
        ServerWorkspace(
            id: workspace.id.uuidString,
            serverId: workspace.serverId,
            projectId: workspace.projectId.uuidString,
            name: workspace.name,
            hasCustomName: workspace.hasCustomName,
            rootDirectory: workspace.rootDirectory,
            isArchived: workspace.isArchived,
            createdAt: ServerDateCoding.string(from: workspace.createdAt)
        )
    }

    static func serverPane(
        from pane: PaneDescriptorState,
        workspaceId: UUID,
        createdAt: Date
    ) -> ServerWorkspacePane {
        let paneType: String
        let resourceKind: String?
        let resourceId: String?
        var metadata: String?
        switch pane.kind {
        case .chat:
            paneType = "chat"
            resourceKind = pane.chatSessionId == nil ? nil : "session"
            resourceId = pane.chatSessionId?.uuidString
        case .terminal:
            paneType = "terminal"
            resourceKind = "terminal"
            resourceId = pane.terminalKey
            let value = NativePaneMetadata(
                attachOnly: pane.attachOnly,
                ownerChatSessionId: pane.ownerChatSessionId
            )
            if let data = try? JSONEncoder().encode(value) {
                metadata = String(data: data, encoding: .utf8)
            }
        case .newTab:
            paneType = "new-tab"
            resourceKind = nil
            resourceId = nil
        case .plugin:
            // Plugin panes publish under a plugin-scoped provider so old
            // clients (which only accept "codevisor") drop them silently
            // instead of misrendering. Metadata carries the plugin identity
            // redundantly, so future providers can evolve the id scheme.
            let pluginId = pane.pluginId ?? "unknown"
            let type = pane.pluginPaneType ?? "pane"
            return ServerWorkspacePane(
                id: pane.id.uuidString,
                workspaceId: workspaceId.uuidString,
                providerId: "plugin:\(pluginId)",
                paneType: type,
                title: pane.name,
                createdAt: ServerDateCoding.string(from: createdAt)
            )
        }
        return ServerWorkspacePane(
            id: pane.id.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: paneType,
            title: pane.name,
            resourceKind: resourceKind,
            resourceId: resourceId,
            metadata: metadata,
            createdAt: ServerDateCoding.string(from: createdAt)
        )
    }

    static func descriptor(from record: ServerWorkspacePane) -> PaneDescriptorState? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        if record.providerId.hasPrefix("plugin:") {
            let pluginId = String(record.providerId.dropFirst("plugin:".count))
            guard !pluginId.isEmpty else { return nil }
            return PaneDescriptorState(
                id: id,
                kind: .plugin,
                name: record.title,
                terminalKey: id.uuidString,
                pluginId: pluginId,
                pluginPaneType: record.paneType
            )
        }
        // Unknown providers still drop silently: the registry remains
        // forward-compatible; renderer support is a client capability.
        guard record.providerId == "codevisor" else { return nil }
        switch record.paneType {
        case "chat":
            let sessionId =
                record.resourceKind == "session"
                ? record.resourceId.flatMap(UUID.init(uuidString:))
                : nil
            return PaneDescriptorState(
                id: id,
                kind: .chat,
                name: record.title,
                terminalKey: id.uuidString,
                chatSessionId: sessionId
            )
        case "terminal":
            let decoded = record.metadata
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(NativePaneMetadata.self, from: $0) }
            return PaneDescriptorState(
                id: id,
                kind: .terminal,
                name: record.title,
                terminalKey: record.resourceId ?? id.uuidString,
                attachOnly: decoded?.attachOnly ?? false,
                ownerChatSessionId: decoded?.ownerChatSessionId
            )
        case "new-tab":
            return PaneDescriptorState(
                id: id,
                kind: .newTab,
                name: record.title,
                terminalKey: id.uuidString
            )
        default:
            // The registry remains forward-compatible; renderer support is a
            // separate client capability and arrives with extension panes.
            return nil
        }
    }

    private static func reconcilePanes(
        in workspace: inout Workspace,
        records: [ServerWorkspacePane],
        protectedLocalPaneIds: Set<UUID>
    ) {
        let remote = records.compactMap { record -> (ServerWorkspacePane, PaneDescriptorState)? in
            descriptor(from: record).map { (record, $0) }
        }
        let remoteIds = Set(remote.map(\.1.id))
        let remoteIdByResourceKey = Dictionary(
            remote.compactMap { record, descriptor in
                resourceKey(record).map { ($0, descriptor.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        for (record, descriptor) in remote {
            if replacePane(id: descriptor.id, with: descriptor, in: &workspace) { continue }
            if let key = resourceKey(record),
                replacePane(resourceKey: key, with: descriptor, in: &workspace)
            {
                continue
            }
            let state = PaneGroupState(
                panes: [descriptor], selectedPaneId: descriptor.id, isVisible: true
            )
            workspace.centerTabs.append(WorkspaceTab(root: .leaf(state)))
        }

        for pane in allPanes(in: workspace) {
            guard !protectedLocalPaneIds.contains(pane.id), !remoteIds.contains(pane.id) else {
                continue
            }
            // Resource matching is an identity-migration fallback, not a
            // reason to retain two panes for one chat. Once the authoritative
            // pane id is present, remove any compatibility pane that refers to
            // the same session.
            if let key = resourceKey(pane), remoteIdByResourceKey[key] != nil {
                _ = removePane(id: pane.id, from: &workspace)
                continue
            }
            _ = removePane(id: pane.id, from: &workspace)
        }
        pruneEmptyCenterTabs(in: &workspace)
        ensureUsableLayout(&workspace)
    }

    private static func allPanes(in workspace: Workspace) -> [PaneDescriptorState] {
        workspace.centerTabs.flatMap { tab in
            tab.root.allGroups.flatMap(\.state.panes)
        } + workspace.bottomGroup.panes
    }

    private static func resourceKey(_ pane: PaneDescriptorState) -> String? {
        switch pane.kind {
        case .chat:
            pane.chatSessionId.map { "session:\($0.uuidString.lowercased())" }
        case .terminal:
            "terminal:\(pane.terminalKey.lowercased())"
        case .newTab, .plugin:
            nil
        }
    }

    private static func resourceKey(_ pane: ServerWorkspacePane) -> String? {
        guard let kind = pane.resourceKind, let id = pane.resourceId else { return nil }
        return "\(kind.lowercased()):\(id.lowercased())"
    }

    private static func replacePane(
        id: UUID,
        with pane: PaneDescriptorState,
        in workspace: inout Workspace
    ) -> Bool {
        replacePane(where: { $0.id == id }, with: pane, in: &workspace)
    }

    private static func replacePane(
        resourceKey key: String,
        with pane: PaneDescriptorState,
        in workspace: inout Workspace
    ) -> Bool {
        replacePane(where: { resourceKey($0) == key }, with: pane, in: &workspace)
    }

    private static func replacePane(
        where matches: (PaneDescriptorState) -> Bool,
        with pane: PaneDescriptorState,
        in workspace: inout Workspace
    ) -> Bool {
        for tabIndex in workspace.centerTabs.indices {
            for group in workspace.centerTabs[tabIndex].root.allGroups {
                guard let paneIndex = group.state.panes.firstIndex(where: matches) else { continue }
                workspace.centerTabs[tabIndex].root = workspace.centerTabs[tabIndex].root.updatingGroup(
                    id: group.id
                ) { state in
                    var state = state
                    let oldId = state.panes[paneIndex].id
                    state.panes[paneIndex] = pane
                    if state.selectedPaneId == oldId { state.selectedPaneId = pane.id }
                    return state
                }
                return true
            }
        }
        if let paneIndex = workspace.bottomGroup.panes.firstIndex(where: matches) {
            let oldId = workspace.bottomGroup.panes[paneIndex].id
            workspace.bottomGroup.panes[paneIndex] = pane
            if workspace.bottomGroup.selectedPaneId == oldId {
                workspace.bottomGroup.selectedPaneId = pane.id
            }
            return true
        }
        return false
    }

    @discardableResult
    private static func removePane(id: UUID, from workspace: inout Workspace) -> Bool {
        var removed = false
        for tabIndex in workspace.centerTabs.indices.reversed() {
            var root = workspace.centerTabs[tabIndex].root
            for group in root.allGroups where group.state.panes.contains(where: { $0.id == id }) {
                root = root.updatingGroup(id: group.id) { state in
                    var state = state
                    removed = state.removePane(id: id) != nil || removed
                    return state
                }
            }
            if let pruned = root.prunedEmptyGroups {
                workspace.centerTabs[tabIndex].root = pruned
            } else {
                workspace.centerTabs.remove(at: tabIndex)
            }
        }
        if workspace.bottomGroup.removePane(id: id) != nil { removed = true }
        return removed
    }

    private static func ensureUsableLayout(_ workspace: inout Workspace) {
        guard workspace.centerTabs.isEmpty else {
            if !workspace.centerTabs.contains(where: { $0.id == workspace.selectedCenterTabId }),
                let firstId = workspace.centerTabs.first?.id
            {
                workspace.selectedCenterTabId = firstId
            }
            return
        }
        let tab = WorkspaceTab(root: .leaf(PaneGroupState()))
        workspace.centerTabs = [tab]
        workspace.selectedCenterTabId = tab.id
    }

    private static func pruneEmptyCenterTabs(in workspace: inout Workspace) {
        workspace.centerTabs = workspace.centerTabs.compactMap { tab in
            guard let root = tab.root.prunedEmptyGroups else { return nil }
            var tab = tab
            tab.root = root
            if root.group(id: tab.activeLeafId) == nil, let first = root.allGroups.first?.id {
                tab.activeLeafId = first
            }
            return tab
        }
    }

    private static func makeWorkspace(
        id: UUID,
        projectId: UUID,
        serverId: String,
        record: ServerWorkspace,
        createdAt: Date,
        worktreeName: String?,
        sessionIds: [UUID],
        usesPaneRegistry: Bool
    ) -> Workspace {
        let tabs: [WorkspaceTab]
        if usesPaneRegistry || sessionIds.isEmpty {
            tabs = [WorkspaceTab(root: .leaf(PaneGroupState()))]
        } else {
            tabs = sessionIds.map {
                WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0)))
            }
        }
        return Workspace(
            id: id,
            name: record.name,
            hasCustomName: record.hasCustomName,
            rootDirectory: record.rootDirectory,
            worktreeName: worktreeName,
            serverId: serverId,
            projectId: projectId,
            centerTabs: tabs,
            bottomGroup: PaneGroupState(),
            createdAt: createdAt,
            isArchived: record.isArchived,
            isServerSynced: true
        )
    }

    private static func date(from value: String) -> Date? {
        try? ServerDateCoding.date(from: value)
    }
}

// Deletion lives outside the class body for the size ratchet.
extension WorkspaceSyncModel {
    /// Drops every workspace stored under a server id — the counterpart of
    /// `ProjectListModel.removeAllRecords` for duplicate machine identities.
    public func removeWorkspaces(serverId: String) {
        for workspace in repository.loadAll() where workspace.serverId == serverId {
            repository.delete(id: workspace.id)
        }
        revision &+= 1
    }

    /// Workspace deletion is safe to apply immediately; the following
    /// coalesced snapshot refreshes session membership as well.
    public func removeWorkspace(id: UUID, serverId: String) {
        guard let workspace = repository.workspace(id: id),
            workspace.serverId == serverId
        else { return }
        sessionsInvalidatedByWorkspaceDeletion[serverId, default: []]
            .formUnion(workspace.chatSessionIds)
        repository.delete(id: id)
        revision &+= 1
    }
}
