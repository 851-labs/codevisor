import Foundation

/// The machine-agnostic snapshot half of ProjectListModel, split from the
/// class body for size limits: any machine's authoritative projects and
/// sessions merge into the shared serverId-keyed repositories, selected or
/// not — the flattened sidebar's data precondition.
extension ProjectListModel {
    public var hasArchivedProjects: Bool {
        projects.contains { $0.serverId == selectedServerId && $0.isArchived }
    }

    /// One machine's authoritative snapshot, merged into the shared
    /// serverId-keyed repositories — machine-agnostic, so BACKGROUND
    /// machines' chats are present (and orderable in a flattened list)
    /// before the user ever selects them. Each server has its own generation:
    /// a newer refresh or identity prune supersedes only that server's fetch.
    @discardableResult
    public func refreshFromServer(
        serverId: String,
        client: any CodevisorServerClienting
    ) async -> ServerNavigationRefreshResult {
        let generation = beginSnapshotRefresh(for: serverId)
        let lifetimeGeneration = recordLifetimeGeneration(for: serverId)
        do {
            let prepared = try await fetchSnapshot(serverId: serverId, client: client)
            guard isCurrentSnapshotRefresh(generation, for: serverId),
                isCurrentRecordLifetime(lifetimeGeneration, for: serverId)
            else {
                return .superseded
            }
            commitSnapshot(prepared, serverId: serverId)
            return .committed
        } catch {
            Log.sync.error(
                "Failed to refresh projects/sessions from server: \(String(describing: error), privacy: .public)"
            )
            return .failed(String(describing: error))
        }
    }

    func beginSnapshotRefresh(for serverId: String) -> UInt64 {
        snapshotRefreshGenerationByServer[serverId, default: 0] &+= 1
        return snapshotRefreshGenerationByServer[serverId, default: 0]
    }

    func isCurrentSnapshotRefresh(_ generation: UInt64, for serverId: String) -> Bool {
        snapshotRefreshGenerationByServer[serverId, default: 0] == generation
    }

    func invalidateSnapshotRefreshes(for serverId: String) {
        snapshotRefreshGenerationByServer[serverId, default: 0] &+= 1
    }

    func recordLifetimeGeneration(for serverId: String) -> UInt64 {
        recordLifetimeGenerationByServer[serverId, default: 0]
    }

    func isCurrentRecordLifetime(_ generation: UInt64, for serverId: String) -> Bool {
        recordLifetimeGenerationByServer[serverId, default: 0] == generation
    }

    func invalidateRecordLifetime(for serverId: String) {
        recordLifetimeGenerationByServer[serverId, default: 0] &+= 1
    }

    func fetchSnapshot(
        serverId: String,
        client: any CodevisorServerClienting
    ) async throws -> PreparedServerNavigationSnapshot {
        async let projectRecords = client.listProjects()
        async let sessionRecords = client.listSessions()
        let (remoteProjectRecords, remoteSessionRecords) = try await (
            projectRecords,
            sessionRecords
        )
        return await ServerNavigationSnapshotBuilder.build(
            projects: remoteProjectRecords,
            sessions: remoteSessionRecords,
            serverId: serverId
        )
    }

    func commitSnapshot(
        _ prepared: PreparedServerNavigationSnapshot,
        serverId: String
    ) {
        for failure in prepared.failures {
            Log.sync.error(
                "Dropping server \(failure.kind, privacy: .public) \(failure.id, privacy: .public) that failed to map: \(failure.description, privacy: .public)"
            )
        }
        workspaceAssignmentsByServer[serverId] = prepared.workspaceAssignments
        let nextProjects = mergeProjects(
            local: projects,
            remote: prepared.projects,
            serverId: serverId
        )
        let previousSessions = sessions
        let nextSessions = mergeSessions(
            local: sessions,
            remote: prepared.sessions,
            serverId: serverId
        )
        if nextProjects != projects {
            projects = nextProjects
            persistProjects()
        }
        if nextSessions != sessions {
            sessions = nextSessions
            persistSessions()
            emitAttentionTransitions(
                from: previousSessions,
                to: nextSessions,
                origin: .snapshot
            )
        }
    }

    /// Sessions visible in a project on the project's OWN machine (not the
    /// selected one) — the flattened sidebar's per-project scope.
    public func fleetSessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == project.serverId
                    && !session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    /// Active projects across EVERY machine — the flattened sidebar's root.
    public var fleetActiveProjects: [Project] {
        projects
            .filter {
                !$0.isArchived && ($0.origin == .codevisor || !fleetSessions(in: $0).isEmpty)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Fleet-wide analog of `activeProjectsByWorkspaceRecency`: every
    /// machine's active projects, ordered by each project's most recent
    /// workspace. The composer's project picker lists these — picking a
    /// project IS picking its machine.
    public func fleetActiveProjectsByWorkspaceRecency(
        _ workspaces: [Workspace]
    ) -> [Project] {
        var latestWorkspaceDates: [String: Date] = [:]
        for workspace in workspaces {
            let key = "\(workspace.serverId)|\(workspace.projectId.uuidString)"
            latestWorkspaceDates[key] = max(
                latestWorkspaceDates[key] ?? .distantPast,
                workspace.createdAt
            )
        }
        return fleetActiveProjects.enumerated().sorted { left, right in
            let leftKey = "\(left.element.serverId)|\(left.element.id.uuidString)"
            let rightKey = "\(right.element.serverId)|\(right.element.id.uuidString)"
            switch (latestWorkspaceDates[leftKey], latestWorkspaceDates[rightKey]) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.offset < right.offset
            }
        }
        .map(\.element)
    }
}
