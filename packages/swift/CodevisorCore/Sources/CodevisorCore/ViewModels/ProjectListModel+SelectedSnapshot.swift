import Foundation

extension ProjectListModel {
    func refreshFromServerIfConfigured() {
        guard serverClient != nil else { return }
        Task { await refreshFromServer() }
    }

    @discardableResult
    public func refreshFromServer() async -> ServerNavigationRefreshResult {
        guard let serverClient else {
            return .failed("No server client is configured.")
        }
        // Snapshot the target server: the fetches below are network
        // round-trips, and the user can switch machines while one is in
        // flight. Every fetched record must be stamped with the server it
        // actually came from — reading the live `selectedServerId` after the
        // awaits would tag one machine's projects with another machine's id.
        let serverId = selectedServerId
        let generation = beginSnapshotRefresh(for: serverId)
        let lifetimeGeneration = recordLifetimeGeneration(for: serverId)
        do {
            try await migrateLegacyCacheIfNeeded(serverId: serverId, client: serverClient)
            let prepared = try await fetchSnapshot(serverId: serverId, client: serverClient)
            // The user switched machines while the fetch was in flight: drop
            // the stale response. The newly selected machine triggers its own
            // refresh, and this one would merge (and persist) another
            // machine's projects into the wrong sidebar.
            guard serverId == selectedServerId,
                isCurrentSnapshotRefresh(generation, for: serverId),
                isCurrentRecordLifetime(lifetimeGeneration, for: serverId)
            else { return .superseded }
            commitSnapshot(prepared, serverId: serverId)
            return .committed
        } catch {
            // Keep the last successful snapshot while the server is unreachable.
            Log.sync.error(
                "Failed to refresh projects/sessions from server: \(String(describing: error), privacy: .public)"
            )
            return .failed(String(describing: error))
        }
    }

    /// Applies the authoritative summary embedded in one live server event.
    /// Returns whether workspace membership changed so the caller can refresh
    /// only workspace metadata, not the full project/session snapshot.
    func applyServerSessionEvent(
        _ event: ServerEventEnvelope,
        serverId: String
    ) async -> ServerSessionEventApplication {
        // Deliberately NOT gated on `selectedServerId`: every machine's rows
        // live in the same serverId-keyed repositories, and a background
        // machine's live events must keep its sessions (and their attention
        // state) current while another machine is on screen.
        let lifetimeGeneration = recordLifetimeGeneration(for: serverId)
        guard
            let update = await ServerNavigationSnapshotBuilder.sessionUpdate(
                from: event,
                serverId: serverId
            ), isCurrentRecordLifetime(lifetimeGeneration, for: serverId)
        else {
            return .requiresFullRefresh
        }

        let session = update.session
        let scopedId = ScopedSessionID(serverId: serverId, id: session.id)
        guard
            !pendingDeletedProjectIds.contains(
                ScopedSessionID(serverId: serverId, id: session.projectId)
            )
        else {
            return .applied(workspaceMembershipChanged: false)
        }

        pendingServerSessionIds.remove(scopedId)
        var reconciled = session
        if pendingArchivedSessionIds.contains(scopedId) {
            if session.isArchived {
                pendingArchivedSessionIds.remove(scopedId)
            } else {
                reconciled.isArchived = true
            }
        }

        var assignments = workspaceAssignmentsByServer[serverId] ?? [:]
        let previousWorkspace = assignments[session.id]
        if let workspaceId = update.workspaceId {
            assignments[session.id] = workspaceId
        } else {
            assignments.removeValue(forKey: session.id)
        }
        workspaceAssignmentsByServer[serverId] = assignments

        var nextSessions = sessions
        var attentionPrevious: ChatSession?
        if let index = nextSessions.firstIndex(where: {
            $0.serverId == serverId && $0.id == session.id
        }) {
            let previous = nextSessions[index]
            attentionPrevious = previous
            if attentionIsNewer(previous, than: reconciled) {
                copyAttention(from: previous, to: &reconciled)
            }
            if (previous.updatedAt ?? previous.createdAt)
                == (reconciled.updatedAt ?? reconciled.createdAt)
            {
                // Metadata-only updates retain their exact array position.
                nextSessions[index] = reconciled
            } else {
                nextSessions.remove(at: index)
                insertByActivity(reconciled, into: &nextSessions)
            }
        } else {
            insertByActivity(reconciled, into: &nextSessions)
        }
        if nextSessions != sessions {
            sessions = nextSessions
            persistSessions()
        }
        // The live event stream is the only origin allowed to ping.
        emitAttentionTransition(old: attentionPrevious, new: reconciled, origin: .liveEvent)
        return .applied(
            workspaceMembershipChanged: previousWorkspace != update.workspaceId
        )
    }

    private func insertByActivity(
        _ session: ChatSession,
        into sessions: inout [ChatSession]
    ) {
        let activity = session.updatedAt ?? session.createdAt
        let index =
            sessions.firstIndex {
                ($0.updatedAt ?? $0.createdAt) < activity
            } ?? sessions.endIndex
        sessions.insert(session, at: index)
    }

    /// The latest authoritative workspace assignment for every session on a
    /// machine. Empty is valid for both older servers and unassigned sessions.
    public func workspaceAssignments(for serverId: String) -> [UUID: UUID] {
        workspaceAssignmentsByServer[serverId] ?? [:]
    }

    /// The only upward reconciliation in the new architecture. Existing
    /// installs may have records that predate the server database; upload that
    /// snapshot once, persist a durable marker, then treat every subsequent
    /// server snapshot as authoritative.
    private func migrateLegacyCacheIfNeeded(
        serverId: String,
        client: any CodevisorServerClienting
    ) async throws {
        guard let legacyMigrationStore else { return }
        let safeServerId = serverId.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let key = "server-authority-v1-\(String(safeServerId))"
        guard legacyMigrationStore.loadData(forKey: key) == nil else { return }
        if let existing = legacyMigrationTasks[key] {
            try await existing.value
            return
        }

        // Snapshot before the first await so a concurrent authoritative
        // refresh cannot clear the legacy cache out from underneath the job.
        let legacyProjects = projects.filter { $0.serverId == serverId }
        let legacySessions = sessions.filter {
            $0.serverId == serverId && !$0.harnessId.isEmpty && $0.hasAgentSession
        }
        let task = Task { @MainActor in
            let knownProjects = Set(try await client.listProjects().compactMap { UUID(uuidString: $0.id) })
            let knownSessions = Set(try await client.listSessions().compactMap { UUID(uuidString: $0.id) })
            for project in legacyProjects where !knownProjects.contains(project.id) {
                _ = try await client.upsertProject(project)
            }
            for session in legacySessions where !knownSessions.contains(session.id) {
                _ = try await client.upsertSession(session)
            }
            try legacyMigrationStore.saveData(Data("completed".utf8), forKey: key)
        }
        legacyMigrationTasks[key] = task
        defer { legacyMigrationTasks[key] = nil }
        try await task.value
    }

    func mergeProjects(local: [Project], remote: [Project], serverId: String) -> [Project] {
        let otherServers = local.filter { $0.serverId != serverId }
        // A snapshot that no longer lists a tombstoned project confirms the
        // deletion; one that still does was fetched before the DELETE landed
        // and must not resurrect the row.
        let remoteIds = Set(remote.map { ScopedSessionID(serverId: serverId, id: $0.id) })
        // Seeing the project in a snapshot is the durable acknowledgement.
        // Until then, retain the optimistic local copy even when this snapshot
        // was fetched before its upsert reached the server.
        pendingServerProjectIds.subtract(remoteIds)
        pendingDeletedProjectIds = pendingDeletedProjectIds.filter {
            $0.serverId != serverId || remoteIds.contains($0)
        }
        let pending = local.filter {
            $0.serverId == serverId
                && pendingServerProjectIds.contains(
                    ScopedSessionID(serverId: serverId, id: $0.id)
                )
                && !pendingDeletedProjectIds.contains(
                    ScopedSessionID(serverId: serverId, id: $0.id)
                )
        }
        let surviving = remote.filter {
            !pendingDeletedProjectIds.contains(ScopedSessionID(serverId: serverId, id: $0.id))
        }
        return (otherServers + pending + surviving).sorted { $0.createdAt > $1.createdAt }
    }

    func mergeSessions(
        local rawLocal: [ChatSession], remote rawRemote: [ChatSession], serverId: String
    ) -> [ChatSession] {
        // Sessions of a tombstoned (optimistically deleted) project go down
        // with it — a pre-DELETE snapshot must not bring them back either.
        let remote = rawRemote.filter {
            !pendingDeletedProjectIds.contains(ScopedSessionID(serverId: serverId, id: $0.projectId))
        }
        let local = rawLocal.filter {
            !pendingDeletedProjectIds.contains(
                ScopedSessionID(serverId: $0.serverId, id: $0.projectId)
            )
        }
        let remoteIds = Set(remote.map { ScopedSessionID(serverId: serverId, id: $0.id) })
        // Seeing the row in a snapshot is the durable acknowledgement. A
        // later refresh can now treat the server copy as fully authoritative.
        pendingServerSessionIds.subtract(remoteIds)
        let otherServers = local.filter { $0.serverId != serverId }
        let pending = local.filter {
            $0.serverId == serverId
                && pendingServerSessionIds.contains(ScopedSessionID(serverId: serverId, id: $0.id))
        }
        let reconciledRemote = remote.map { session -> ChatSession in
            let scopedId = ScopedSessionID(serverId: serverId, id: session.id)
            guard pendingArchivedSessionIds.contains(scopedId) else { return session }
            if session.isArchived {
                // This snapshot was taken after the archive reached the
                // server, so future server state can be authoritative again.
                pendingArchivedSessionIds.remove(scopedId)
                return session
            }
            // Preserve all newer remote metadata while holding only the
            // optimistic archived flag against this stale snapshot.
            var archived = session
            archived.isArchived = true
            return archived
        }
        let missingPendingArchives = pendingArchivedSessionIds.filter {
            $0.serverId == serverId && !remoteIds.contains($0)
        }
        pendingArchivedSessionIds.subtract(missingPendingArchives)
        return (otherServers + pending + reconciledRemote).sorted {
            ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt)
        }
    }
}
