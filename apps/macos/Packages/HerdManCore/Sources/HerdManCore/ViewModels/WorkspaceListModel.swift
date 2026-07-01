import Foundation
import Observation

/// Manages the sidebar's workspaces and their sessions, including archiving.
@MainActor
@Observable
public final class WorkspaceListModel {
    public private(set) var workspaces: [Workspace] = []
    public private(set) var sessions: [ChatSession] = []
    public private(set) var selectedServerId: String
    /// Whether imported (non-HerdMan) sessions are shown. Synced from settings.
    public var showsImportedSessions: Bool = true

    private let workspaceRepository: any WorkspaceRepository
    private let sessionRepository: any SessionRepository
    private var serverClient: (any HerdManServerClienting)?

    public init(
        workspaceRepository: any WorkspaceRepository,
        sessionRepository: any SessionRepository,
        selectedServerId: String = "local",
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.workspaceRepository = workspaceRepository
        self.sessionRepository = sessionRepository
        self.selectedServerId = selectedServerId
        self.serverClient = serverClient
        load()
        refreshFromServerIfConfigured()
    }

    public func load() {
        workspaces = workspaceRepository.load()
        sessions = sessionRepository.load()
    }

    /// Workspaces shown in the main section: user-added ones always appear;
    /// imported ones only when they have a visible session.
    public var activeWorkspaces: [Workspace] {
        workspaces
            .filter {
                $0.serverId == selectedServerId
                    && !$0.isArchived
                    && ($0.origin == .herdman || hasVisibleSessions(in: $0))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Workspaces in the archived section.
    public var archivedWorkspaces: [Workspace] {
        workspaces
            .filter { $0.serverId == selectedServerId && $0.isArchived }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var hasArchivedWorkspaces: Bool {
        workspaces.contains { $0.serverId == selectedServerId && $0.isArchived }
    }

    /// Adds a workspace for a folder, reusing an existing entry if the folder
    /// is already present (un-archiving it if needed).
    @discardableResult
    public func addWorkspace(folderURL: URL) -> Workspace {
        if let index = workspaces.firstIndex(where: { $0.serverId == selectedServerId && $0.folderURL == folderURL }) {
            workspaces[index].isArchived = false
            persistWorkspaces()
            syncWorkspace(workspaces[index])
            return workspaces[index]
        }
        let workspace = Workspace.fromFolder(folderURL, serverId: selectedServerId)
        workspaces.append(workspace)
        persistWorkspaces()
        syncWorkspace(workspace)
        return workspace
    }

    public func archive(_ workspace: Workspace) {
        setArchived(true, for: workspace)
    }

    public func unarchive(_ workspace: Workspace) {
        setArchived(false, for: workspace)
    }

    /// Sets the SF Symbol icon for a workspace.
    public func setIcon(_ symbolName: String, for workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].symbolName = symbolName
        persistWorkspaces()
        syncWorkspace(workspaces[index])
    }

    public func removeWorkspace(_ workspace: Workspace) {
        let removedSessionIDs = sessions
            .filter { $0.serverId == selectedServerId && $0.workspaceId == workspace.id }
            .map(\.id)
        workspaces.removeAll { $0.id == workspace.id }
        sessions.removeAll { $0.serverId == selectedServerId && $0.workspaceId == workspace.id }
        persistWorkspaces()
        persistSessions()
        deleteWorkspaceFromServer(workspace.id, removedSessionIDs: removedSessionIDs)
    }

    /// Active sessions belonging to a workspace, newest first. Imported sessions
    /// are hidden unless `showsImportedSessions` is on.
    public func sessions(in workspace: Workspace) -> [ChatSession] {
        sessions
            .filter { session in
                session.workspaceId == workspace.id
                    && session.serverId == selectedServerId
                    && !session.isArchived
                    && (session.origin == .herdman || showsImportedSessions)
            }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
    }

    /// True if a workspace has any visible session (after import gating).
    public func hasVisibleSessions(in workspace: Workspace) -> Bool {
        !sessions(in: workspace).isEmpty
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
        in workspace: Workspace,
        title: String = "New Session",
        harnessId: String? = nil,
        syncToServer: Bool = true
    ) -> ChatSession {
        let session = ChatSession(
            workspaceId: workspace.id,
            serverId: selectedServerId,
            harnessId: harnessId ?? "",
            title: title,
            origin: .herdman
        )
        sessions.append(session)
        persistSessions()
        if syncToServer {
            syncSession(session)
        }
        return session
    }

    /// Records the agent-side session id once a brand-new session is created.
    public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].agentSessionId = agentSessionId
        persistSessions()
        syncSession(sessions[index])
    }

    /// Imports sessions discovered from harnesses, creating workspaces by cwd and
    /// skipping any already known (by harness + agent session id).
    public func importSessions(_ imported: [ImportedSession]) {
        for item in imported {
            let alreadyKnown = sessions.contains {
                $0.harnessId == item.harnessId && $0.agentSessionId == item.info.sessionId
            }
            if alreadyKnown { continue }
            let workspace = findOrCreateWorkspace(folderURL: URL(fileURLWithPath: item.info.cwd))
            let timestamp = ISO8601DateFormatter().date(from: item.info.updatedAt ?? "")
            sessions.append(ChatSession(
                workspaceId: workspace.id,
                serverId: selectedServerId,
                harnessId: item.harnessId,
                agentSessionId: item.info.sessionId,
                title: item.info.title ?? "Session",
                origin: .imported,
                createdAt: timestamp ?? Date(),
                updatedAt: timestamp
            ))
        }
        persistWorkspaces()
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

    /// Removes all workspaces and sessions (used by "Delete all data").
    public func removeAll() {
        let workspaceIDs = workspaces.filter { $0.serverId == selectedServerId }.map(\.id)
        let sessionIDs = sessions.filter { $0.serverId == selectedServerId }.map(\.id)
        workspaces.removeAll { $0.serverId == selectedServerId }
        sessions.removeAll { $0.serverId == selectedServerId }
        persistWorkspaces()
        persistSessions()
        deleteAllFromServer(workspaceIDs: workspaceIDs, sessionIDs: sessionIDs)
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

    /// Finds a workspace by folder, or creates one (without changing archive
    /// state). Used by the importer so it doesn't un-archive existing folders.
    private func findOrCreateWorkspace(folderURL: URL) -> Workspace {
        if let existing = workspaces.first(where: { $0.serverId == selectedServerId && $0.folderURL == folderURL }) {
            return existing
        }
        let workspace = Workspace.fromFolder(folderURL, serverId: selectedServerId, origin: .imported)
        workspaces.append(workspace)
        return workspace
    }

    private func setArchived(_ archived: Bool, for workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].isArchived = archived
        persistWorkspaces()
        syncWorkspace(workspaces[index])
    }

    private func persistWorkspaces() {
        workspaceRepository.save(workspaces)
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
            let serverWorkspaces = try await serverClient.listWorkspaces()
            let serverSessions = try await serverClient.listSessions()
            workspaces = mergeWorkspaces(
                local: workspaces,
                remote: serverWorkspaces.compactMap { try? $0.workspace(serverId: selectedServerId) }
            )
            sessions = mergeSessions(
                local: sessions,
                remote: serverSessions.compactMap { try? $0.chatSession(serverId: selectedServerId) }
            )
            persistWorkspaces()
            persistSessions()
        } catch {
            // The local file cache remains authoritative until the server is reachable.
        }
    }

    private func mergeWorkspaces(local: [Workspace], remote: [Workspace]) -> [Workspace] {
        let otherServers = local.filter { $0.serverId != selectedServerId }
        let selectedLocal = local.filter { $0.serverId == selectedServerId }
        var merged = Dictionary(uniqueKeysWithValues: selectedLocal.map { ($0.id, $0) })
        for workspace in remote {
            merged[workspace.id] = workspace
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

    private func syncWorkspace(_ workspace: Workspace) {
        guard let serverClient else { return }
        Task { _ = try? await serverClient.upsertWorkspace(workspace) }
    }

    private func syncSession(_ session: ChatSession) {
        guard let serverClient, !session.harnessId.isEmpty else { return }
        let workspace = workspaces.first { $0.serverId == selectedServerId && $0.id == session.workspaceId }
        Task {
            if let workspace {
                _ = try? await serverClient.upsertWorkspace(workspace)
            }
            _ = try? await serverClient.upsertSession(session)
        }
    }

    private func syncAllToServer() {
        guard let serverClient else { return }
        let currentWorkspaces = workspaces.filter { $0.serverId == selectedServerId }
        let currentSessions = sessions.filter { $0.serverId == selectedServerId && !$0.harnessId.isEmpty }
        Task {
            for workspace in currentWorkspaces {
                _ = try? await serverClient.upsertWorkspace(workspace)
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

    private func deleteWorkspaceFromServer(_ workspaceID: UUID, removedSessionIDs: [UUID]) {
        guard let serverClient else { return }
        Task {
            for sessionID in removedSessionIDs {
                try? await serverClient.deleteSession(id: sessionID)
            }
            try? await serverClient.deleteWorkspace(id: workspaceID)
        }
    }

    private func deleteAllFromServer(workspaceIDs: [UUID], sessionIDs: [UUID]) {
        guard let serverClient else { return }
        Task {
            for sessionID in sessionIDs {
                try? await serverClient.deleteSession(id: sessionID)
            }
            for workspaceID in workspaceIDs {
                try? await serverClient.deleteWorkspace(id: workspaceID)
            }
        }
    }
}
