import Foundation

extension WorkspaceSyncModel {
    struct WorkspaceAdoptionResult {
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
    func adoptLocalWorkspaces(
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
    func publishWorkspaceIfNeeded(
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

    func backfillLocalPanes(
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
}
