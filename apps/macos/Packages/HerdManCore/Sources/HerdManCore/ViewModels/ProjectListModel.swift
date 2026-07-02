import Foundation
import Observation

/// Manages the sidebar's projects and their sessions, including archiving.
@MainActor
@Observable
public final class ProjectListModel {
    public private(set) var projects: [Project] = []
    public private(set) var sessions: [ChatSession] = []
    public private(set) var selectedServerId: String
    /// Whether imported (non-HerdMan) sessions are shown. Synced from settings.
    public var showsImportedSessions: Bool = true

    private let projectRepository: any ProjectRepository
    private let sessionRepository: any SessionRepository
    private var serverClient: (any HerdManServerClienting)?

    public init(
        projectRepository: any ProjectRepository,
        sessionRepository: any SessionRepository,
        selectedServerId: String = "local",
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.projectRepository = projectRepository
        self.sessionRepository = sessionRepository
        self.selectedServerId = selectedServerId
        self.serverClient = serverClient
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
                    && ($0.origin == .herdman || hasVisibleSessions(in: $0))
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
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].symbolName = symbolName
        persistProjects()
        syncProject(projects[index])
    }

    public func removeProject(_ project: Project) {
        let removedSessionIDs = sessions
            .filter { $0.serverId == selectedServerId && $0.projectId == project.id }
            .map(\.id)
        projects.removeAll { $0.id == project.id }
        sessions.removeAll { $0.serverId == selectedServerId && $0.projectId == project.id }
        persistProjects()
        persistSessions()
        deleteProjectFromServer(project.id, removedSessionIDs: removedSessionIDs)
    }

    /// Active sessions belonging to a project, newest first. Imported sessions
    /// are hidden unless `showsImportedSessions` is on.
    public func sessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == selectedServerId
                    && !session.isArchived
                    && (session.origin == .herdman || showsImportedSessions)
            }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    /// True if a project has any visible session (after import gating).
    public func hasVisibleSessions(in project: Project) -> Bool {
        !sessions(in: project).isEmpty
    }

    /// Archives a session, removing it from the active list without deleting it.
    public func archiveSession(_ session: ChatSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
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
            serverId: selectedServerId,
            harnessId: harnessId ?? "",
            title: title,
            origin: .herdman,
            worktreeName: worktreeName,
            cwd: cwd
        )
        sessions.append(session)
        persistSessions()
        if syncToServer {
            syncSession(session)
        }
        return session
    }

    /// Marks conversation activity (a finished assistant turn) on a session
    /// that runs in-app, where the server never sees the transcript. Bumps the
    /// recency stamp locally and mirrors it to the server.
    public func touchSession(_ sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let now = Date()
        sessions[index].updatedAt = now
        persistSessions()
        guard let serverClient else { return }
        Task { try? await serverClient.touchSession(id: sessionId, updatedAt: now) }
    }

    /// Records the agent-side session id once a brand-new session is created.
    public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].agentSessionId = agentSessionId
        persistSessions()
        syncSession(sessions[index])
    }

    /// Imports sessions discovered from harnesses, creating projects by cwd and
    /// skipping any already known (by harness + agent session id).
    public func importSessions(_ imported: [ImportedSession]) {
        for item in imported {
            let alreadyKnown = sessions.contains {
                $0.harnessId == item.harnessId && $0.agentSessionId == item.info.sessionId
            }
            if alreadyKnown { continue }
            let project = findOrCreateProject(folderURL: URL(fileURLWithPath: item.info.cwd))
            let timestamp = ISO8601DateFormatter().date(from: item.info.updatedAt ?? "")
            sessions.append(ChatSession(
                projectId: project.id,
                serverId: selectedServerId,
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
    public func importSessions(_ imported: [ImportedSession], into project: Project) {
        var didImport = false
        for item in imported {
            let alreadyKnown = sessions.contains {
                $0.harnessId == item.harnessId && $0.agentSessionId == item.info.sessionId
            }
            if alreadyKnown { continue }
            let timestamp = ISO8601DateFormatter().date(from: item.info.updatedAt ?? "")
            sessions.append(ChatSession(
                projectId: project.id,
                serverId: selectedServerId,
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
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].title = title
        persistSessions()
        syncSession(sessions[index])
    }

    public func deleteSession(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        persistSessions()
        deleteSessionFromServer(session.id)
    }

    /// Applies a deletion that already happened on the server (from another
    /// client's event); intentionally does not call back to the server.
    public func removeSessionLocally(id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        sessions.removeAll { $0.id == id }
        persistSessions()
    }

    /// Applies a project deletion that already happened on the server.
    public func removeProjectLocally(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        sessions.removeAll { $0.projectId == id }
        persistProjects()
        persistSessions()
    }

    /// Removes all projects and sessions (used by "Delete all data").
    public func removeAll() {
        let projectIDs = projects.filter { $0.serverId == selectedServerId }.map(\.id)
        let sessionIDs = sessions.filter { $0.serverId == selectedServerId }.map(\.id)
        projects.removeAll { $0.serverId == selectedServerId }
        sessions.removeAll { $0.serverId == selectedServerId }
        persistProjects()
        persistSessions()
        deleteAllFromServer(projectIDs: projectIDs, sessionIDs: sessionIDs)
    }

    public func selectServer(
        serverId: String,
        serverClient: (any HerdManServerClienting)?,
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
    private func findOrCreateProject(folderURL: URL) -> Project {
        if let existing = projects.first(where: { $0.serverId == selectedServerId && $0.folderURL == folderURL }) {
            return existing
        }
        let project = Project.fromFolder(folderURL, serverId: selectedServerId, origin: .imported)
        projects.append(project)
        return project
    }

    private func setArchived(_ archived: Bool, for project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
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
        do {
            let remoteProjects = try await serverClient.listProjects()
                .compactMap { try? $0.project(serverId: selectedServerId) }
            let remoteSessions = try await serverClient.listSessions()
                .compactMap { try? $0.chatSession(serverId: selectedServerId) }
            projects = mergeProjects(local: projects, remote: remoteProjects)
            sessions = mergeSessions(local: sessions, remote: remoteSessions)
            persistProjects()
            persistSessions()
            // Reconcile upward too: anything created while this server was
            // unreachable (or before it ever ran) exists only in the local
            // cache. Push it so the server — and every other client of it —
            // catches up.
            await pushMissingToServer(
                knownProjectIds: Set(remoteProjects.map(\.id)),
                knownSessionIds: Set(remoteSessions.map(\.id))
            )
        } catch {
            // The local file cache remains authoritative until the server is reachable.
        }
    }

    private func pushMissingToServer(knownProjectIds: Set<UUID>, knownSessionIds: Set<UUID>) async {
        guard let serverClient else { return }
        let missingProjects = projects.filter {
            $0.serverId == selectedServerId && !knownProjectIds.contains($0.id)
        }
        // Drafts (no agent session yet) stay local until their first send.
        let missingSessions = sessions.filter {
            $0.serverId == selectedServerId && !$0.harnessId.isEmpty
                && $0.agentSessionId != nil && !knownSessionIds.contains($0.id)
        }
        for project in missingProjects {
            _ = try? await serverClient.upsertProject(project)
        }
        for session in missingSessions {
            _ = try? await serverClient.upsertSession(session)
        }
    }

    private func mergeProjects(local: [Project], remote: [Project]) -> [Project] {
        let otherServers = local.filter { $0.serverId != selectedServerId }
        let selectedLocal = local.filter { $0.serverId == selectedServerId }
        var merged = Dictionary(uniqueKeysWithValues: selectedLocal.map { ($0.id, $0) })
        for project in remote {
            merged[project.id] = project
        }
        return (otherServers + merged.values).sorted { $0.createdAt > $1.createdAt }
    }

    private func mergeSessions(local: [ChatSession], remote: [ChatSession]) -> [ChatSession] {
        let otherServers = local.filter { $0.serverId != selectedServerId }
        let selectedLocal = local.filter { $0.serverId == selectedServerId }
        var merged = Dictionary(uniqueKeysWithValues: selectedLocal.map { ($0.id, $0) })
        for session in remote {
            merged[session.id] = session
        }
        return (otherServers + merged.values).sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    private func syncProject(_ project: Project) {
        guard let serverClient else { return }
        Task { _ = try? await serverClient.upsertProject(project) }
    }

    private func syncSession(_ session: ChatSession) {
        guard let serverClient, !session.harnessId.isEmpty else { return }
        let project = projects.first { $0.serverId == selectedServerId && $0.id == session.projectId }
        Task {
            if let project {
                _ = try? await serverClient.upsertProject(project)
            }
            _ = try? await serverClient.upsertSession(session)
        }
    }

    private func syncAllToServer() {
        guard let serverClient else { return }
        let currentProjects = projects.filter { $0.serverId == selectedServerId }
        let currentSessions = sessions.filter { $0.serverId == selectedServerId && !$0.harnessId.isEmpty }
        Task {
            for project in currentProjects {
                _ = try? await serverClient.upsertProject(project)
            }
            for session in currentSessions {
                _ = try? await serverClient.upsertSession(session)
            }
        }
    }

    private func deleteSessionFromServer(_ sessionID: UUID) {
        guard let serverClient else { return }
        Task { try? await serverClient.deleteSession(id: sessionID) }
    }

    private func deleteProjectFromServer(_ projectID: UUID, removedSessionIDs: [UUID]) {
        guard let serverClient else { return }
        Task {
            for sessionID in removedSessionIDs {
                try? await serverClient.deleteSession(id: sessionID)
            }
            try? await serverClient.deleteProject(id: projectID)
        }
    }

    private func deleteAllFromServer(projectIDs: [UUID], sessionIDs: [UUID]) {
        guard let serverClient else { return }
        Task {
            for sessionID in sessionIDs {
                try? await serverClient.deleteSession(id: sessionID)
            }
            for projectID in projectIDs {
                try? await serverClient.deleteProject(id: projectID)
            }
        }
    }
}
