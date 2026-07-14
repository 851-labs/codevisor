import Foundation
import Observation

/// Manages the sidebar's projects and their sessions, including archiving.
@MainActor
@Observable
public final class ProjectListModel {
    private struct ScopedSessionID: Hashable {
        let serverId: String
        let id: UUID
    }

    public private(set) var projects: [Project] = []
    public private(set) var sessions: [ChatSession] = []
    public private(set) var selectedServerId: String
    /// Whether imported (non-Codevisor) sessions are shown. Synced from settings.
    public var showsImportedSessions: Bool = true

    private let projectRepository: any ProjectRepository
    private let sessionRepository: any SessionRepository
    /// Present only in the live app. It records the one-time handoff from the
    /// old JSON authority to the server so legacy metadata is uploaded once,
    /// never reconciled bidirectionally on every refresh.
    private let legacyMigrationStore: (any PersistenceStore)?
    private var legacyMigrationTasks: [String: Task<Void, Error>] = [:]
    private var serverClient: (any CodevisorServerClienting)?
    /// Sessions created locally while a server client is active, but not yet
    /// observed in an authoritative server snapshot. A metadata refresh can
    /// race the slow first agent startup; preserving these rows prevents the
    /// selected session from disappearing until creation is acknowledged.
    private var pendingServerSessionIds: Set<ScopedSessionID> = []
    /// Shared: `ISO8601DateFormatter()` construction is milliseconds-expensive
    /// and the import loops used to build one per imported session.
    private static let importTimestampFormatter = ISO8601DateFormatter()

    public init(
        projectRepository: any ProjectRepository,
        sessionRepository: any SessionRepository,
        selectedServerId: String = "local",
        serverClient: (any CodevisorServerClienting)? = nil,
        legacyMigrationStore: (any PersistenceStore)? = nil
    ) {
        self.projectRepository = projectRepository
        self.sessionRepository = sessionRepository
        self.selectedServerId = selectedServerId
        self.serverClient = serverClient
        self.legacyMigrationStore = legacyMigrationStore
        load()
        refreshFromServerIfConfigured()
    }

    public func load() {
        projects = projectRepository.load()
        sessions = sessionRepository.load()
    }

    /// Projects shown in the main section: user-added ones always appear;
    /// imported ones only when they have a visible session.
    public var activeProjects: [Project] {
        projects
            .filter {
                $0.serverId == selectedServerId
                    && !$0.isArchived
                    && ($0.origin == .codevisor || hasVisibleSessions(in: $0))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Projects in the archived section.
    public var archivedProjects: [Project] {
        projects
            .filter { $0.serverId == selectedServerId && $0.isArchived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var hasArchivedProjects: Bool {
        projects.contains { $0.serverId == selectedServerId && $0.isArchived }
    }

    /// Adds a project for a folder, reusing an existing entry if the folder
    /// is already present (un-archiving it if needed).
    @discardableResult
    public func addProject(folderURL: URL) -> Project {
        if let index = projects.firstIndex(where: { $0.serverId == selectedServerId && $0.folderURL == folderURL }) {
            projects[index].isArchived = false
            persistProjects()
            syncProject(projects[index])
            return projects[index]
        }
        let project = Project.fromFolder(folderURL, serverId: selectedServerId)
        projects.append(project)
        persistProjects()
        syncProject(project)
        return project
    }

    public func archive(_ project: Project) {
        setArchived(true, for: project)
    }

    public func unarchive(_ project: Project) {
        setArchived(false, for: project)
    }

    /// Sets the SF Symbol icon for a project.
    public func setIcon(_ symbolName: String, for project: Project) {
        guard let index = projects.firstIndex(where: {
            $0.serverId == project.serverId && $0.id == project.id
        }) else { return }
        projects[index].symbolName = symbolName
        persistProjects()
        syncProject(projects[index])
    }

    public func removeProject(_ project: Project) {
        let removedSessionIDs = sessions
            .filter { $0.serverId == project.serverId && $0.projectId == project.id }
            .map(\.id)
        pendingServerSessionIds.subtract(removedSessionIDs.map {
            ScopedSessionID(serverId: project.serverId, id: $0)
        })
        projects.removeAll { $0.serverId == project.serverId && $0.id == project.id }
        sessions.removeAll { $0.serverId == project.serverId && $0.projectId == project.id }
        persistProjects()
        persistSessions()
        deleteProjectFromServer(
            project.id,
            serverId: project.serverId,
            removedSessionIDs: removedSessionIDs
        )
    }

    /// Active sessions belonging to a project, newest first. Imported sessions
    /// are hidden unless `showsImportedSessions` is on.
    public func sessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == selectedServerId
                    && !session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    /// True if a project has any visible session (after import gating).
    public func hasVisibleSessions(in project: Project) -> Bool {
        !sessions(in: project).isEmpty
    }

    /// Archives a session, removing it from the active list without deleting it.
    public func archiveSession(_ session: ChatSession) {
        guard let index = sessions.firstIndex(where: {
            $0.serverId == session.serverId && $0.id == session.id
        }) else { return }
        sessions[index].isArchived = true
        persistSessions()
        syncSession(sessions[index])
    }

    @discardableResult
    public func newSession(
        in project: Project,
        title: String = "New Session",
        harnessId: String? = nil,
        worktreeName: String? = nil,
        cwd: String? = nil,
        syncToServer: Bool = true
    ) -> ChatSession {
        let session = ChatSession(
            projectId: project.id,
            // Inherit the project's server: a machine switch between opening
            // the composer and sending must not file the session elsewhere.
            serverId: project.serverId,
            harnessId: harnessId ?? "",
            title: title,
            origin: .codevisor,
            worktreeName: worktreeName,
            cwd: cwd
        )
        sessions.append(session)
        // Even deferred first-send sessions are already in the process of
        // being created by SessionController. Only mark rows when a client is
        // configured: JSON records loaded before server authority is selected
        // are legacy cache, not active in-flight creations.
        if serverClient != nil {
            pendingServerSessionIds.insert(ScopedSessionID(serverId: session.serverId, id: session.id))
        }
        persistSessions()
        if syncToServer {
            syncSession(session)
        }
        return session
    }

    /// Marks conversation activity (a finished assistant turn) on a session
    /// that runs in-app, where the server never sees the transcript. Bumps the
    /// recency stamp locally and mirrors it to the server.
    public func touchSession(_ sessionId: UUID, serverId: String) {
        guard let index = sessions.firstIndex(where: {
            $0.serverId == serverId && $0.id == sessionId
        }) else { return }
        let now = Date()
        sessions[index].updatedAt = now
        persistSessions()
        guard let serverClient, serverId == selectedServerId else { return }
        Task {
            do {
                try await serverClient.touchSession(id: sessionId, updatedAt: now)
            } catch {
                // Recency-only mirror; the next sync carries the stamp.
                Log.sync.debug(
                    "Failed to touch session \(sessionId.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Records the worktree a draft session ended up running in. The session
    /// record is created before the worktree exists (the session page opens
    /// while setup streams progress), so the name/cwd land here afterwards.
    /// Local only: the draft hasn't been synced yet, and the first connect
    /// upserts the session carrying this worktree name.
    public func setWorktree(name: String, cwd: String, for sessionId: UUID, serverId: String) {
        guard let index = sessions.firstIndex(where: {
            $0.serverId == serverId && $0.id == sessionId
        }) else { return }
        sessions[index].worktreeName = name
        sessions[index].cwd = cwd
        persistSessions()
    }

    /// Records the agent-side session id once a brand-new session is created.
    public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID, serverId: String) {
        guard let index = sessions.firstIndex(where: {
            $0.serverId == serverId && $0.id == sessionId
        }) else { return }
        sessions[index].agentSessionId = agentSessionId
        persistSessions()
        syncSession(sessions[index])
    }

    /// Imports sessions discovered from harnesses, creating projects by cwd and
    /// skipping any already known (by harness + agent session id).
    ///
    /// `serverId` is the machine the sessions were discovered on, snapshotted
    /// by the caller BEFORE the async discovery ran. Discovery is a network
    /// round-trip; tagging results with the live `selectedServerId` here would
    /// file another machine's sessions (and their projects) under whichever
    /// machine the user has switched to meanwhile.
    public func importSessions(_ imported: [ImportedSession], serverId: String) {
        for item in imported {
            let alreadyKnown = sessions.contains {
                $0.serverId == serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }
            if alreadyKnown { continue }
            let project = findOrCreateProject(
                folderURL: URL(fileURLWithPath: item.info.cwd),
                serverId: serverId
            )
            let timestamp = Self.importTimestampFormatter.date(from: item.info.updatedAt ?? "")
            sessions.append(ChatSession(
                projectId: project.id,
                serverId: serverId,
                harnessId: item.harnessId,
                agentSessionId: item.info.sessionId,
                title: item.info.title ?? "Session",
                origin: .imported,
                createdAt: timestamp ?? Date(),
                updatedAt: timestamp
            ))
        }
        persistProjects()
        persistSessions()
        syncAllToServer()
    }

    /// Imports sessions into a specific project (they were discovered for its
    /// folder), skipping any already known (by harness + agent session id).
    /// Sessions inherit the project's server, not the currently selected one:
    /// the user may confirm a pending import after switching machines.
    public func importSessions(_ imported: [ImportedSession], into project: Project) {
        var didImport = false
        for item in imported {
            let alreadyKnown = sessions.contains {
                $0.serverId == project.serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }
            if alreadyKnown { continue }
            let timestamp = Self.importTimestampFormatter.date(from: item.info.updatedAt ?? "")
            sessions.append(ChatSession(
                projectId: project.id,
                serverId: project.serverId,
                harnessId: item.harnessId,
                agentSessionId: item.info.sessionId,
                title: item.info.title ?? "Session",
                origin: .imported,
                createdAt: timestamp ?? Date(),
                updatedAt: timestamp
            ))
            didImport = true
        }
        guard didImport else { return }
        persistSessions()
        syncAllToServer()
    }

    public func renameSession(_ session: ChatSession, to title: String) {
        guard let index = sessions.firstIndex(where: {
            $0.serverId == session.serverId && $0.id == session.id
        }) else { return }
        sessions[index].title = title
        persistSessions()
        syncSession(sessions[index])
    }

    public func deleteSession(_ session: ChatSession) {
        pendingServerSessionIds.remove(ScopedSessionID(serverId: session.serverId, id: session.id))
        sessions.removeAll { $0.serverId == session.serverId && $0.id == session.id }
        persistSessions()
        deleteSessionFromServer(session.id, serverId: session.serverId)
    }

    /// Applies a deletion that already happened on the server (from another
    /// client's event); intentionally does not call back to the server.
    public func removeSessionLocally(id: UUID, serverId: String) {
        guard sessions.contains(where: { $0.serverId == serverId && $0.id == id }) else { return }
        pendingServerSessionIds.remove(ScopedSessionID(serverId: serverId, id: id))
        sessions.removeAll { $0.serverId == serverId && $0.id == id }
        persistSessions()
    }

    /// Applies a project deletion that already happened on the server.
    public func removeProjectLocally(id: UUID, serverId: String) {
        guard projects.contains(where: { $0.serverId == serverId && $0.id == id }) else { return }
        let removedSessionIds = sessions.lazy
            .filter { $0.serverId == serverId && $0.projectId == id }
            .map { ScopedSessionID(serverId: serverId, id: $0.id) }
        pendingServerSessionIds.subtract(removedSessionIds)
        projects.removeAll { $0.serverId == serverId && $0.id == id }
        sessions.removeAll { $0.serverId == serverId && $0.projectId == id }
        persistProjects()
        persistSessions()
    }

    /// Removes all projects and sessions (used by "Delete all data").
    public func removeAll() {
        let projectIDs = projects.filter { $0.serverId == selectedServerId }.map(\.id)
        let sessionIDs = sessions.filter { $0.serverId == selectedServerId }.map(\.id)
        pendingServerSessionIds.subtract(sessionIDs.map {
            ScopedSessionID(serverId: selectedServerId, id: $0)
        })
        projects.removeAll { $0.serverId == selectedServerId }
        sessions.removeAll { $0.serverId == selectedServerId }
        persistProjects()
        persistSessions()
        deleteAllFromServer(projectIDs: projectIDs, sessionIDs: sessionIDs)
    }

    public func selectServer(
        serverId: String,
        serverClient: (any CodevisorServerClienting)?,
        refresh: Bool = true
    ) {
        selectedServerId = serverId
        self.serverClient = serverClient
        if refresh {
            Task { await refreshFromServer() }
        }
    }

    // MARK: - Private

    /// Finds a project by folder, or creates one (without changing archive
    /// state). Used by the importer so it doesn't un-archive existing folders.
    private func findOrCreateProject(folderURL: URL, serverId: String) -> Project {
        if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
            return existing
        }
        let project = Project.fromFolder(folderURL, serverId: serverId, origin: .imported)
        projects.append(project)
        return project
    }

    private func setArchived(_ archived: Bool, for project: Project) {
        guard let index = projects.firstIndex(where: {
            $0.serverId == project.serverId && $0.id == project.id
        }) else { return }
        projects[index].isArchived = archived
        persistProjects()
        syncProject(projects[index])
    }

    private func persistProjects() {
        projectRepository.save(projects)
    }

    private func persistSessions() {
        sessionRepository.save(sessions)
    }

    private func refreshFromServerIfConfigured() {
        guard serverClient != nil else { return }
        Task { await refreshFromServer() }
    }

    public func refreshFromServer() async {
        guard let serverClient else { return }
        // Snapshot the target server: the fetches below are network
        // round-trips, and the user can switch machines while one is in
        // flight. Every fetched record must be stamped with the server it
        // actually came from — reading the live `selectedServerId` after the
        // awaits would tag one machine's projects with another machine's id.
        let serverId = selectedServerId
        do {
            try await migrateLegacyCacheIfNeeded(serverId: serverId, client: serverClient)
            let remoteProjects = try await serverClient.listProjects()
                .compactMap { record -> Project? in
                    do {
                        return try record.project(serverId: serverId)
                    } catch {
                        // Drop the unmappable row rather than failing the list.
                        Log.sync.error(
                            "Dropping server project \(record.id, privacy: .public) that failed to map: \(String(describing: error), privacy: .public)"
                        )
                        return nil
                    }
                }
            let remoteSessions = try await serverClient.listSessions()
                .compactMap { record -> ChatSession? in
                    do {
                        return try record.chatSession(serverId: serverId)
                    } catch {
                        Log.sync.error(
                            "Dropping server session \(record.id, privacy: .public) that failed to map: \(String(describing: error), privacy: .public)"
                        )
                        return nil
                    }
                }
            // The user switched machines while the fetch was in flight: drop
            // the stale response. The newly selected machine triggers its own
            // refresh, and this one would merge (and persist) another
            // machine's projects into the wrong sidebar.
            guard serverId == selectedServerId else { return }
            projects = mergeProjects(local: projects, remote: remoteProjects, serverId: serverId)
            sessions = mergeSessions(local: sessions, remote: remoteSessions, serverId: serverId)
            persistProjects()
            persistSessions()
        } catch {
            // Keep the last successful snapshot while the server is unreachable.
            Log.sync.error(
                "Failed to refresh projects/sessions from server: \(String(describing: error), privacy: .public)"
            )
        }
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
            $0.serverId == serverId && !$0.harnessId.isEmpty && $0.agentSessionId != nil
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

    private func mergeProjects(local: [Project], remote: [Project], serverId: String) -> [Project] {
        let otherServers = local.filter { $0.serverId != serverId }
        return (otherServers + remote).sorted { $0.createdAt > $1.createdAt }
    }

    private func mergeSessions(local: [ChatSession], remote: [ChatSession], serverId: String) -> [ChatSession] {
        let remoteIds = Set(remote.map { ScopedSessionID(serverId: serverId, id: $0.id) })
        // Seeing the row in a snapshot is the durable acknowledgement. A
        // later refresh can now treat the server copy as fully authoritative.
        pendingServerSessionIds.subtract(remoteIds)
        let otherServers = local.filter { $0.serverId != serverId }
        let pending = local.filter {
            $0.serverId == serverId
                && pendingServerSessionIds.contains(ScopedSessionID(serverId: serverId, id: $0.id))
        }
        return (otherServers + pending + remote).sorted {
            ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt)
        }
    }

    /// Mirrors a record to the server it belongs to. The client at hand is the
    /// currently selected machine's, so records from another machine are NOT
    /// pushed here.
    private func syncProject(_ project: Project) {
        guard let serverClient, project.serverId == selectedServerId else { return }
        Task {
            do {
                _ = try await serverClient.upsertProject(project)
            } catch {
                Log.sync.error(
                    "Failed to sync project \(project.id.uuidString, privacy: .public) to the server: \(String(describing: error), privacy: .public)"
                )
                ErrorReporter.shared.report("Couldn't Sync the Project to the Server", error: error)
            }
        }
    }

    private func syncSession(_ session: ChatSession) {
        guard let serverClient, !session.harnessId.isEmpty,
              session.serverId == selectedServerId else { return }
        let project = projects.first { $0.serverId == session.serverId && $0.id == session.projectId }
        Task {
            do {
                if let project {
                    _ = try await serverClient.upsertProject(project)
                }
                _ = try await serverClient.upsertSession(session)
                pendingServerSessionIds.remove(
                    ScopedSessionID(serverId: session.serverId, id: session.id)
                )
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

    private func syncAllToServer() {
        guard let serverClient else { return }
        let currentProjects = projects.filter { $0.serverId == selectedServerId }
        let currentSessions = sessions.filter { $0.serverId == selectedServerId && !$0.harnessId.isEmpty }
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
                    "Couldn't Sync to the Server",
                    message: "Some items couldn't be uploaded. They'll be retried the next time they change."
                )
            }
        }
    }

    private func deleteSessionFromServer(_ sessionID: UUID, serverId: String) {
        guard let serverClient, serverId == selectedServerId else { return }
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

    private func deleteProjectFromServer(
        _ projectID: UUID,
        serverId: String,
        removedSessionIDs: [UUID]
    ) {
        guard let serverClient, serverId == selectedServerId else { return }
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
                Log.sync.error(
                    "Failed to delete project \(projectID.uuidString, privacy: .public) on the server: \(String(describing: error), privacy: .public)"
                )
            }
            if didFail { reportServerDeleteFailure() }
        }
    }

    private func deleteAllFromServer(projectIDs: [UUID], sessionIDs: [UUID]) {
        guard let serverClient else { return }
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
    private func reportServerDeleteFailure() {
        ErrorReporter.shared.report(
            "Couldn't Delete on the Server",
            message: "It may reappear the next time the list refreshes."
        )
    }
}
