import Foundation
import Observation

/// Manages the sidebar's workspaces and their sessions, including archiving.
@MainActor
@Observable
public final class WorkspaceListModel {
    public private(set) var workspaces: [Workspace] = []
    public private(set) var sessions: [ChatSession] = []
    /// Whether imported (non-HerdMan) sessions are shown. Synced from settings.
    public var showsImportedSessions: Bool = true

    private let workspaceRepository: any WorkspaceRepository
    private let sessionRepository: any SessionRepository

    public init(
        workspaceRepository: any WorkspaceRepository,
        sessionRepository: any SessionRepository
    ) {
        self.workspaceRepository = workspaceRepository
        self.sessionRepository = sessionRepository
        load()
    }

    public func load() {
        workspaces = workspaceRepository.load()
        sessions = sessionRepository.load()
    }

    /// Workspaces shown in the main section: user-added ones always appear;
    /// imported ones only when they have a visible session.
    public var activeWorkspaces: [Workspace] {
        workspaces
            .filter { !$0.isArchived && ($0.origin == .herdman || hasVisibleSessions(in: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Workspaces in the archived section.
    public var archivedWorkspaces: [Workspace] {
        workspaces.filter(\.isArchived).sorted { $0.createdAt > $1.createdAt }
    }

    public var hasArchivedWorkspaces: Bool {
        workspaces.contains(where: \.isArchived)
    }

    /// Adds a workspace for a folder, reusing an existing entry if the folder
    /// is already present (un-archiving it if needed).
    @discardableResult
    public func addWorkspace(folderURL: URL) -> Workspace {
        if let index = workspaces.firstIndex(where: { $0.folderURL == folderURL }) {
            workspaces[index].isArchived = false
            persistWorkspaces()
            return workspaces[index]
        }
        let workspace = Workspace.fromFolder(folderURL)
        workspaces.append(workspace)
        persistWorkspaces()
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
    }

    public func removeWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        sessions.removeAll { $0.workspaceId == workspace.id }
        persistWorkspaces()
        persistSessions()
    }

    /// Active sessions belonging to a workspace, newest first. Imported sessions
    /// are hidden unless `showsImportedSessions` is on.
    public func sessions(in workspace: Workspace) -> [ChatSession] {
        sessions
            .filter { session in
                session.workspaceId == workspace.id
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
    }

    @discardableResult
    public func newSession(in workspace: Workspace, title: String = "New Session", harnessId: String? = nil) -> ChatSession {
        let session = ChatSession(workspaceId: workspace.id, harnessId: harnessId ?? "", title: title, origin: .herdman)
        sessions.append(session)
        persistSessions()
        return session
    }

    /// Records the agent-side session id once a brand-new session is created.
    public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].agentSessionId = agentSessionId
        persistSessions()
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
    }

    public func renameSession(_ session: ChatSession, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index].title = title
        persistSessions()
    }

    public func deleteSession(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        persistSessions()
    }

    /// Removes all workspaces and sessions (used by "Delete all data").
    public func removeAll() {
        workspaces = []
        sessions = []
        persistWorkspaces()
        persistSessions()
    }

    // MARK: - Private

    /// Finds a workspace by folder, or creates one (without changing archive
    /// state). Used by the importer so it doesn't un-archive existing folders.
    private func findOrCreateWorkspace(folderURL: URL) -> Workspace {
        if let existing = workspaces.first(where: { $0.folderURL == folderURL }) {
            return existing
        }
        let workspace = Workspace.fromFolder(folderURL, origin: .imported)
        workspaces.append(workspace)
        return workspace
    }

    private func setArchived(_ archived: Bool, for workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].isArchived = archived
        persistWorkspaces()
    }

    private func persistWorkspaces() {
        workspaceRepository.save(workspaces)
    }

    private func persistSessions() {
        sessionRepository.save(sessions)
    }
}
