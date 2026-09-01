import Foundation

/// The model's server write-through: optimistic upserts and deletes for the
/// selected machine, with pending markers keeping authoritative refreshes
/// from flickering optimistic rows. Extracted from ProjectListModel.swift
/// (file-length ratchet); behavior unchanged.
extension ProjectListModel {
    /// Installs fleet routing without making any machine the navigation
    /// selection. Every mutation subsequently resolves its record's client.
    public func configureServerClientProvider(
        _ provider: @escaping (String) -> (any CodevisorServerClienting)?
    ) {
        serverClientProvider = provider
    }

    func clientForServer(_ serverId: String) -> (any CodevisorServerClienting)? {
        if let serverClientProvider { return serverClientProvider(serverId) }
        guard serverId == selectedServerId else { return nil }
        return serverClient
    }

    func syncProject(_ project: Project) {
        guard let serverClient = clientForServer(project.serverId) else { return }
        pendingServerProjectIds.insert(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        Task {
            do {
                _ = try await serverClient.upsertProject(project)
            } catch {
                Log.sync.error(
                    "Failed to sync project \(project.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                )
                ErrorReporter.shared.report(
                    .projectSyncFailed,
                    title: "Couldn't Sync the Project to the Server",
                    error: error
                )
            }
        }
    }

    func syncSession(_ session: ChatSession) {
        // No harness gate: eagerly created chats (workspace "New Chat"
        // tabs) have no harness until their first send, and MUST still
        // reach the server — an unsynced row is dropped by the next
        // authoritative refresh once its pending marker is gone.
        guard let serverClient = clientForServer(session.serverId) else { return }
        let project = projects.first { $0.serverId == session.serverId && $0.id == session.projectId }
        Task {
            do {
                if let project {
                    _ = try await serverClient.upsertProject(project)
                }
                _ = try await serverClient.upsertSession(session)
                // A successful write can still overtake an older list request.
                // mergeSessions retires the marker once a snapshot contains it.
            } catch {
                // Keep the optimistic row pending. A later mutation can retry
                // the upsert, and authoritative refreshes must not make the
                // active session flicker out merely because the server is slow
                // or temporarily unreachable.
                Log.sync.error(
                    "Failed to sync session \(session.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    func syncAllToServer(serverId: String) {
        guard let serverClient = clientForServer(serverId) else { return }
        let currentProjects = projects.filter { $0.serverId == serverId }
        let currentSessions = sessions.filter { $0.serverId == serverId && !$0.harnessId.isEmpty }
        Task {
            var failureCount = 0
            for project in currentProjects {
                do {
                    _ = try await serverClient.upsertProject(project)
                } catch {
                    failureCount += 1
                    Log.sync.error(
                        "Failed to sync project \(project.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            for session in currentSessions {
                do {
                    _ = try await serverClient.upsertSession(session)
                } catch {
                    failureCount += 1
                    Log.sync.error(
                        "Failed to sync session \(session.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            if failureCount > 0 {
                ErrorReporter.shared.report(
                    .bulkSyncFailed,
                    title: "Couldn't Sync to the Server",
                    message: "Some items couldn't be uploaded. They'll be retried the next time they change."
                )
            }
        }
    }

    func deleteSessionFromServer(_ sessionID: UUID, serverId: String) {
        guard let serverClient = clientForServer(serverId) else { return }
        Task {
            do {
                try await serverClient.deleteSession(id: sessionID)
            } catch {
                Log.sync.error(
                    "Failed to delete session \(sessionID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                )
                reportServerDeleteFailure()
            }
        }
    }

    func deleteProjectFromServer(
        _ projectID: UUID,
        serverId: String,
        removedSessionIDs: [UUID]
    ) {
        guard let serverClient = clientForServer(serverId) else { return }
        Task {
            var didFail = false
            for sessionID in removedSessionIDs {
                do {
                    try await serverClient.deleteSession(id: sessionID)
                } catch {
                    didFail = true
                    Log.sync.error(
                        "Failed to delete session \(sessionID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            do {
                try await serverClient.deleteProject(id: projectID)
            } catch {
                didFail = true
                // The project survived on the server; drop the tombstone so
                // the next snapshot restores the truth instead of holding an
                // optimistic deletion forever.
                pendingDeletedProjectIds.remove(
                    ScopedSessionID(serverId: serverId, id: projectID)
                )
                Log.sync.error(
                    "Failed to delete project \(projectID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                )
            }
            if didFail { reportServerDeleteFailure() }
        }
    }

    func deleteAllFromServer(
        serverId: String,
        projectIDs: [UUID],
        sessionIDs: [UUID]
    ) {
        guard let serverClient = clientForServer(serverId) else { return }
        Task {
            var didFail = false
            for sessionID in sessionIDs {
                do {
                    try await serverClient.deleteSession(id: sessionID)
                } catch {
                    didFail = true
                    Log.sync.error(
                        "Failed to delete session \(sessionID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            for projectID in projectIDs {
                do {
                    try await serverClient.deleteProject(id: projectID)
                } catch {
                    didFail = true
                    Log.sync.error(
                        "Failed to delete project \(projectID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            if didFail { reportServerDeleteFailure() }
        }
    }

    /// One banner per user-initiated delete action, even when a bulk delete
    /// fails for several records.
    func reportServerDeleteFailure() {
        ErrorReporter.shared.report(
            .serverDeleteFailed,
            title: "Couldn't Delete on the Server",
            message: "It may reappear the next time the list refreshes."
        )
    }
}
