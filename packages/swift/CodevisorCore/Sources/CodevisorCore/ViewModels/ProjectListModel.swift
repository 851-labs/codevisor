import Foundation
import Observation

struct PreparedServerNavigationSnapshot: Sendable {
    struct MappingFailure: Sendable {
        let kind: String
        let id: String
        let description: String
    }

    let projects: [Project]
    let sessions: [ChatSession]
    let workspaceAssignments: [UUID: UUID]
    let failures: [MappingFailure]
}

struct PreparedServerSessionUpdate: Sendable {
    let session: ChatSession
    let workspaceId: UUID?
}

/// Pure server-record conversion belongs off the main actor. Only the final
/// observable diff is committed by `ProjectListModel` on the UI actor.
enum ServerNavigationSnapshotBuilder {
    static func build(
        projects: [ServerProject],
        sessions: [ServerSession],
        serverId: String
    ) async -> PreparedServerNavigationSnapshot {
        await Task.detached(priority: .userInitiated) {
            var failures: [PreparedServerNavigationSnapshot.MappingFailure] = []
            let mappedProjects = projects.compactMap { record -> Project? in
                do {
                    return try record.project(serverId: serverId)
                } catch {
                    failures.append(
                        .init(
                            kind: "project",
                            id: record.id,
                            description: String(describing: error)
                        ))
                    return nil
                }
            }
            let mappedSessions = sessions.compactMap { record -> ChatSession? in
                do {
                    return try record.chatSession(serverId: serverId)
                } catch {
                    failures.append(
                        .init(
                            kind: "session",
                            id: record.id,
                            description: String(describing: error)
                        ))
                    return nil
                }
            }
            var assignments: [UUID: UUID] = [:]
            for record in sessions {
                guard let sessionId = UUID(uuidString: record.id),
                    let rawWorkspaceId = record.workspaceId,
                    let workspaceId = UUID(uuidString: rawWorkspaceId)
                else { continue }
                assignments[sessionId] = workspaceId
            }
            return PreparedServerNavigationSnapshot(
                projects: mappedProjects,
                sessions: mappedSessions,
                workspaceAssignments: assignments,
                failures: failures
            )
        }.value
    }

    static func sessionUpdate(
        from event: ServerEventEnvelope,
        serverId: String
    ) async -> PreparedServerSessionUpdate? {
        await Task.detached(priority: .userInitiated) {
            guard let record = try? event.sessionRecord(),
                let session = try? record.chatSession(serverId: serverId)
            else { return nil }
            return PreparedServerSessionUpdate(
                session: session,
                workspaceId: record.workspaceId.flatMap(UUID.init(uuidString:))
            )
        }.value
    }
}

enum ServerSessionEventApplication: Sendable, Equatable {
    case applied(workspaceMembershipChanged: Bool)
    case requiresFullRefresh
}

/// Manages the sidebar's projects and their sessions, including archiving.
@MainActor
@Observable
public final class ProjectListModel {
    struct ScopedSessionID: Hashable, Codable, Sendable {
        let serverId: String
        let id: UUID
    }

    public internal(set) var projects: [Project] = []
    public internal(set) var sessions: [ChatSession] = []
    public private(set) var selectedServerId: String
    /// Fires whenever a session's attention state changes, from every path
    /// that can change it (live events, snapshot merges, local mutations).
    /// `SessionAttentionCoordinator` consumes these to drive focus auto-read
    /// and edge-triggered notifications.
    @ObservationIgnored public var onAttentionTransition: ((SessionAttentionTransition) -> Void)?
    /// Whether imported (non-Codevisor) sessions are shown. Synced from settings.
    public var showsImportedSessions: Bool = true

    private let projectRepository: any ProjectRepository
    private let sessionRepository: any SessionRepository
    let markerPersistenceOwner = UUID()
    /// Present only in the live app. It records the one-time handoff from the
    /// old JSON authority to the server so legacy metadata is uploaded once,
    /// never reconciled bidirectionally on every refresh.
    let legacyMigrationStore: (any PersistenceStore)?
    var legacyMigrationTasks: [String: Task<Void, Error>] = [:]
    var serverClient: (any CodevisorServerClienting)?
    /// Fleet-aware resolver installed by `MachineController`.
    @ObservationIgnored var serverClientProvider: ((String) -> (any CodevisorServerClienting)?)?
    /// Server-owned session → workspace membership, scoped by the client-side
    /// machine id. Pane layout stays in `WorkspaceRepository`; this mapping is
    /// refreshed with the same authoritative session snapshot as the sidebar.
    @ObservationIgnored var workspaceAssignmentsByServer: [String: [UUID: UUID]] = [:]
    /// Monotonic per-machine snapshot epochs. Removing a machine identity
    /// advances its epoch even when it has no committed rows yet, so a list
    /// request already in flight cannot repopulate records after the prune.
    @ObservationIgnored var snapshotRefreshGenerationByServer: [String: UInt64] = [:]
    /// Unlike snapshot generations, this changes only when an identity's
    /// entire record lifetime ends. It also fences a live event whose mapping
    /// was already suspended when that identity was pruned.
    @ObservationIgnored var recordLifetimeGenerationByServer: [String: UInt64] = [:]
    /// Sessions created locally while a server client is active, but not yet
    /// observed in an authoritative server snapshot. A metadata refresh can
    /// race the slow first agent startup; preserving these rows prevents the
    /// selected session from disappearing until creation is acknowledged.
    /// PERSISTED (piggybacking the metadata store): losing the marker to a
    /// relaunch while the sync hadn't landed (offline remote, app quit mid-
    /// flight) let the next refresh silently discard a real local session.
    var pendingServerSessionIds: Set<ScopedSessionID> = [] {
        didSet {
            guard pendingServerSessionIds != oldValue else { return }
            persistPendingServerSessions()
        }
    }
    /// Project upserts not yet observed in an authoritative server snapshot.
    /// Upserts and list refreshes are independent requests, so an older
    /// snapshot can otherwise erase a newly added project between the user's
    /// add action and the server acknowledgement.
    // Internal so split-off extension files (fleet project adds) reach it.
    var pendingServerProjectIds: Set<ScopedSessionID> = [] {
        didSet {
            guard pendingServerProjectIds != oldValue else { return }
            persistPendingServerProjects()
        }
    }
    /// Archives are optimistic: the row leaves the sidebar before the server
    /// round-trip completes. Keep that local state authoritative until a
    /// server snapshot actually acknowledges `isArchived`, otherwise an
    /// older in-flight snapshot briefly resurrects the row.
    var pendingArchivedSessionIds: Set<ScopedSessionID> = [] {
        didSet {
            guard pendingArchivedSessionIds != oldValue else { return }
            persistPendingArchivedSessions()
        }
    }
    /// Project deletions are optimistic too: the rows leave immediately
    /// while the server DELETE is in flight. A refresh snapshot fetched in
    /// that window (an archive PATCH fans out events that trigger one) still
    /// lists the project and its sessions — merging it back resurrected a
    /// just-discarded scratch chat, and the sidebar then even minted a fresh
    /// workspace for it. Tombstone the id until a snapshot confirms the
    /// deletion (the project is absent) or the DELETE fails.
    var pendingDeletedProjectIds: Set<ScopedSessionID> = []

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
        loadPendingServerProjects()
        loadPendingServerSessions()
        loadPendingArchivedSessions()
        // A project added just before the previous process exited remains
        // protected from an older server snapshot and retries its upload.
        for pending in pendingServerProjectIds {
            if let project = projects.first(where: {
                $0.serverId == pending.serverId && $0.id == pending.id
            }) {
                syncProject(project)
            } else {
                pendingServerProjectIds.remove(pending)
            }
        }
        // Unconfirmed local sessions survive relaunches AND retry their
        // sync (the fire-and-forget upsert may have died with the app).
        for pending in pendingServerSessionIds {
            if let session = sessions.first(where: {
                $0.serverId == pending.serverId && $0.id == pending.id
            }) {
                syncSession(session)
            }
        }
        // A quit while an archive upload was in flight must not let the next
        // launch's initial server refresh revive the row. Retry the archived
        // record; the marker clears once a matching snapshot is observed.
        for pending in pendingArchivedSessionIds {
            if let session = sessions.first(where: {
                $0.serverId == pending.serverId && $0.id == pending.id && $0.isArchived
            }) {
                syncSession(session)
            } else {
                pendingArchivedSessionIds.remove(pending)
            }
        }
        refreshFromServerIfConfigured()
    }

    public func load() {
        projects = projectRepository.load()
        sessions = sessionRepository.load()
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
        if clientForServer(session.serverId) != nil {
            pendingServerSessionIds.insert(ScopedSessionID(serverId: session.serverId, id: session.id))
        }
        persistSessions()
        if syncToServer {
            syncSession(session)
        }
        return session
    }

    /// Records the worktree a draft session ended up running in. The session
    /// record is created before the worktree exists (the session page opens
    /// while setup streams progress), so the name/cwd land here afterwards.
    /// Local only: the draft hasn't been synced yet, and the first connect
    /// upserts the session carrying this worktree name.
    public func setWorktree(name: String, cwd: String, for sessionId: UUID, serverId: String) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        sessions[index].worktreeName = name
        sessions[index].cwd = cwd
        persistSessions()
    }

    /// Records the agent-side session id once a brand-new session is created.
    public func setAgentSessionId(_ agentSessionId: String, for sessionId: UUID, serverId: String) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        sessions[index].agentSessionId = agentSessionId
        persistSessions()
        syncSession(sessions[index])
    }

    /// Fills in an eagerly created session's first-send details. Workspace
    /// "New Chat" tabs register their session at CREATION (so the sidebar
    /// shows them immediately, already stamped with the workspace's
    /// worktree/cwd) but keep the new-chat composer until the first message —
    /// which is when the title and chosen harness become known. A manual
    /// rename before the first message wins over the prompt-derived title.
    @discardableResult
    public func updateSessionForFirstSend(
        _ session: ChatSession,
        title: String,
        harnessId: String?
    ) -> ChatSession? {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return nil }
        if sessions[index].title == "New Chat" {
            sessions[index].title = title
        }
        if let harnessId {
            sessions[index].harnessId = harnessId
        }
        persistSessions()
        syncSession(sessions[index])
        return sessions[index]
    }

    public func renameSession(_ session: ChatSession, to title: String) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return }
        sessions[index].title = title
        persistSessions()
        syncSession(sessions[index])
    }

    public func deleteSession(_ session: ChatSession) {
        let scopedId = ScopedSessionID(serverId: session.serverId, id: session.id)
        pendingServerSessionIds.remove(scopedId)
        pendingArchivedSessionIds.remove(scopedId)
        sessions.removeAll { $0.serverId == session.serverId && $0.id == session.id }
        persistSessions()
        deleteSessionFromServer(session.id, serverId: session.serverId)
    }

    /// Applies a deletion that already happened on the server (from another
    /// client's event); intentionally does not call back to the server.
    @discardableResult
    public func removeSessionLocally(id: UUID, serverId: String) -> Bool {
        let previousWorkspace = workspaceAssignmentsByServer[serverId]?.removeValue(forKey: id)
        guard sessions.contains(where: { $0.serverId == serverId && $0.id == id }) else {
            return previousWorkspace != nil
        }
        let scopedId = ScopedSessionID(serverId: serverId, id: id)
        pendingServerSessionIds.remove(scopedId)
        pendingArchivedSessionIds.remove(scopedId)
        sessions.removeAll { $0.serverId == serverId && $0.id == id }
        persistSessions()
        return previousWorkspace != nil
    }

    /// Applies a project deletion that already happened on the server.
    public func removeProjectLocally(id: UUID, serverId: String) {
        pendingServerProjectIds.remove(
            ScopedSessionID(serverId: serverId, id: id)
        )
        guard projects.contains(where: { $0.serverId == serverId && $0.id == id }) else { return }
        let removedSessionIds = sessions.lazy
            .filter { $0.serverId == serverId && $0.projectId == id }
            .map { ScopedSessionID(serverId: serverId, id: $0.id) }
        for sessionId in removedSessionIds {
            workspaceAssignmentsByServer[serverId]?.removeValue(forKey: sessionId.id)
        }
        pendingServerSessionIds.subtract(removedSessionIds)
        pendingArchivedSessionIds.subtract(removedSessionIds)
        projects.removeAll { $0.serverId == serverId && $0.id == id }
        sessions.removeAll { $0.serverId == serverId && $0.projectId == id }
        persistProjects()
        persistSessions()
    }

    /// Removes all projects and sessions (used by "Delete all data").
    public func removeAll() {
        let projectIDs = projects.filter { $0.serverId == selectedServerId }.map(\.id)
        let sessionIDs = sessions.filter { $0.serverId == selectedServerId }.map(\.id)
        pendingServerProjectIds.subtract(
            projectIDs.map {
                ScopedSessionID(serverId: selectedServerId, id: $0)
            })
        pendingServerSessionIds.subtract(
            sessionIDs.map {
                ScopedSessionID(serverId: selectedServerId, id: $0)
            })
        pendingArchivedSessionIds.subtract(
            sessionIDs.map {
                ScopedSessionID(serverId: selectedServerId, id: $0)
            })
        projects.removeAll { $0.serverId == selectedServerId }
        sessions.removeAll { $0.serverId == selectedServerId }
        persistProjects()
        persistSessions()
        deleteAllFromServer(serverId: selectedServerId, projectIDs: projectIDs, sessionIDs: sessionIDs)
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

    func persistProjects() {
        projectRepository.save(projects)
    }

    func persistSessions() {
        sessionRepository.save(sessions)
    }

}
