import Foundation

/// The machine-agnostic snapshot half of ProjectListModel, split from the
/// class body for size limits: any machine's authoritative projects and
/// sessions merge into the shared serverId-keyed repositories, selected or
/// not — the flattened sidebar's data precondition.
extension ProjectListModel {
    /// One machine's authoritative snapshot, merged into the shared
    /// serverId-keyed repositories — machine-agnostic, so BACKGROUND
    /// machines' chats are present (and orderable in a flattened list)
    /// before the user ever selects them. No supersession here: merges are
    /// per-server and idempotent, and a background fetch can never clobber
    /// another machine's rows.
    @discardableResult
    public func refreshFromServer(
        serverId: String,
        client: any CodevisorServerClienting
    ) async -> ServerNavigationRefreshResult {
        do {
            let prepared = try await fetchSnapshot(serverId: serverId, client: client)
            commitSnapshot(prepared, serverId: serverId)
            return .committed
        } catch {
            Log.sync.error(
                "Failed to refresh projects/sessions from server: \(String(describing: error), privacy: .public)"
            )
            return .failed(String(describing: error))
        }
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
}
