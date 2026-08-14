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
    public private(set) var revision: UInt64 = 0

    private let repository: any WorkspaceRepository
    private let projectList: ProjectListModel
    @ObservationIgnored private var sessionsInvalidatedByWorkspaceDeletion: [String: Set<UUID>] = [:]
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

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
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            guard let records = try await client.listWorkspaces(),
                projectList.selectedServerId == serverId,
                generation == refreshGeneration
            else { return }
            reconcile(records, serverId: serverId)
        } catch {
            Log.sync.error(
                "Failed to refresh workspaces from server: \(String(describing: error), privacy: .public)"
            )
        }
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

    private func reconcile(_ records: [ServerWorkspace], serverId: String) {
        let assignments = projectList.workspaceAssignments(for: serverId)
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
                    symbolName: record.symbolName ?? source.symbolName,
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
                    sessionIds: sessionIds
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
            workspace.symbolName = record.symbolName ?? workspace.symbolName
            workspace.isArchived = record.isArchived
            workspace.isServerSynced = true

            for sessionId in sessionIds where workspace.tabId(containingChat: sessionId) == nil {
                workspace.centerTabs.append(
                    WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId)))
                )
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

    private static func makeWorkspace(
        id: UUID,
        projectId: UUID,
        serverId: String,
        record: ServerWorkspace,
        createdAt: Date,
        worktreeName: String?,
        sessionIds: [UUID]
    ) -> Workspace {
        let tabs: [WorkspaceTab]
        let bottom: PaneGroupState
        if sessionIds.isEmpty {
            var state = PaneGroupState()
            _ = state.addNewTabPane()
            tabs = [WorkspaceTab(root: .leaf(state))]
            bottom = PaneGroupState()
        } else {
            tabs = sessionIds.map {
                WorkspaceTab(root: .leaf(.centerInitial(sessionId: $0)))
            }
            bottom = .initial(sessionId: sessionIds[0])
        }
        return Workspace(
            id: id,
            name: record.name,
            hasCustomName: record.hasCustomName,
            rootDirectory: record.rootDirectory,
            worktreeName: worktreeName,
            symbolName: record.symbolName,
            serverId: serverId,
            projectId: projectId,
            centerTabs: tabs,
            bottomGroup: bottom,
            createdAt: createdAt,
            isArchived: record.isArchived,
            isServerSynced: true
        )
    }

    private static func date(from value: String) -> Date? {
        try? ServerDateCoding.date(from: value)
    }
}
