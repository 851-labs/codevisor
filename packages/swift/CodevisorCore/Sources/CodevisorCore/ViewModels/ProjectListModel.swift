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
    private struct ScopedSessionID: Hashable, Codable, Sendable {
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
    private let markerPersistenceOwner = UUID()
    /// Present only in the live app. It records the one-time handoff from the
    /// old JSON authority to the server so legacy metadata is uploaded once,
    /// never reconciled bidirectionally on every refresh.
    private let legacyMigrationStore: (any PersistenceStore)?
    private var legacyMigrationTasks: [String: Task<Void, Error>] = [:]
    private var serverClient: (any CodevisorServerClienting)?
    /// Server-owned session → workspace membership, scoped by the client-side
    /// machine id. Pane layout stays in `WorkspaceRepository`; this mapping is
    /// refreshed with the same authoritative session snapshot as the sidebar.
    @ObservationIgnored var workspaceAssignmentsByServer: [String: [UUID: UUID]] = [:]
    /// Sessions created locally while a server client is active, but not yet
    /// observed in an authoritative server snapshot. A metadata refresh can
    /// race the slow first agent startup; preserving these rows prevents the
    /// selected session from disappearing until creation is acknowledged.
    /// PERSISTED (piggybacking the metadata store): losing the marker to a
    /// relaunch while the sync hadn't landed (offline remote, app quit mid-
    /// flight) let the next refresh silently discard a real local session.
    private var pendingServerSessionIds: Set<ScopedSessionID> = [] {
        didSet {
            guard pendingServerSessionIds != oldValue else { return }
            persistPendingServerSessions()
        }
    }
    /// Project upserts not yet observed in an authoritative server snapshot.
    /// Upserts and list refreshes are independent requests, so an older
    /// snapshot can otherwise erase a newly added project between the user's
    /// add action and the server acknowledgement.
    private var pendingServerProjectIds: Set<ScopedSessionID> = [] {
        didSet {
            guard pendingServerProjectIds != oldValue else { return }
            persistPendingServerProjects()
        }
    }
    /// Archives are optimistic: the row leaves the sidebar before the server
    /// round-trip completes. Keep that local state authoritative until a
    /// server snapshot actually acknowledges `isArchived`, otherwise an
    /// older in-flight snapshot briefly resurrects the row.
    private var pendingArchivedSessionIds: Set<ScopedSessionID> = [] {
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
    private var pendingDeletedProjectIds: Set<ScopedSessionID> = []

    private static let pendingServerSessionsKey = "pending-server-sessions-v1"
    private static let pendingServerProjectsKey = "pending-server-projects-v1"
    private static let pendingArchivedSessionsKey = "pending-archived-sessions-v1"

    private func persistPendingServerProjects() {
        guard let legacyMigrationStore else { return }
        let snapshot = Array(pendingServerProjectIds)
        let storageKey = Self.pendingServerProjectsKey
        PersistenceEncoding.enqueueLatest(
            owner: markerPersistenceOwner,
            key: storageKey,
            delay: 0.05
        ) {
            do {
                let data = try PersistenceEncoding.encoder.encode(snapshot)
                try legacyMigrationStore.saveData(data, forKey: storageKey)
            } catch {
                Log.sync.error(
                    "Failed to persist pending project markers: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func loadPendingServerProjects() {
        guard let legacyMigrationStore,
            let data = legacyMigrationStore.loadData(forKey: Self.pendingServerProjectsKey),
            let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
        else { return }
        pendingServerProjectIds = Set(ids)
    }

    private func persistPendingServerSessions() {
        guard let legacyMigrationStore else { return }
        let snapshot = Array(pendingServerSessionIds)
        let storageKey = Self.pendingServerSessionsKey
        PersistenceEncoding.enqueueLatest(
            owner: markerPersistenceOwner,
            key: storageKey,
            delay: 0.05
        ) {
            do {
                let data = try PersistenceEncoding.encoder.encode(snapshot)
                try legacyMigrationStore.saveData(data, forKey: storageKey)
            } catch {
                Log.sync.error(
                    "Failed to persist pending session markers: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func loadPendingServerSessions() {
        guard let legacyMigrationStore,
            let data = legacyMigrationStore.loadData(forKey: Self.pendingServerSessionsKey),
            let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
        else { return }
        pendingServerSessionIds = Set(ids)
    }

    private func persistPendingArchivedSessions() {
        guard let legacyMigrationStore else { return }
        let snapshot = Array(pendingArchivedSessionIds)
        let storageKey = Self.pendingArchivedSessionsKey
        PersistenceEncoding.enqueueLatest(
            owner: markerPersistenceOwner,
            key: storageKey,
            delay: 0.05
        ) {
            do {
                let data = try PersistenceEncoding.encoder.encode(snapshot)
                try legacyMigrationStore.saveData(data, forKey: storageKey)
            } catch {
                Log.sync.error(
                    "Failed to persist pending archived session markers: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func loadPendingArchivedSessions() {
        guard let legacyMigrationStore,
            let data = legacyMigrationStore.loadData(forKey: Self.pendingArchivedSessionsKey),
            let ids = try? JSONDecoder().decode([ScopedSessionID].self, from: data)
        else { return }
        pendingArchivedSessionIds = Set(ids)
    }
    /// Shared: formatter construction is milliseconds-expensive and the
    /// import loops used to build one per imported session. Native scanners
    /// emit JavaScript ISO strings with fractional seconds; legacy servers may
    /// still return whole-second timestamps, so accept both forms.
    private static let fractionalImportTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondImportTimestampFormatter = ISO8601DateFormatter()

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

    /// Orders active projects by the most recent workspace created for each
    /// one. Projects without workspace history retain their normal
    /// newest-project-first order after projects that have been used.
    public func activeProjectsByWorkspaceRecency(
        _ workspaces: [Workspace]
    ) -> [Project] {
        var latestWorkspaceDates: [UUID: Date] = [:]
        for workspace in workspaces where workspace.serverId == selectedServerId {
            latestWorkspaceDates[workspace.projectId] = max(
                latestWorkspaceDates[workspace.projectId] ?? .distantPast,
                workspace.createdAt
            )
        }

        return activeProjects.enumerated().sorted { left, right in
            switch (
                latestWorkspaceDates[left.element.id],
                latestWorkspaceDates[right.element.id]
            ) {
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

    /// Registers a project the selected server already owns (a fresh
    /// clone-from-git) under the server's project id, so the local list and
    /// the server describe one project instead of merging by folder later.
    @discardableResult
    public func adoptServerProject(id: UUID, folderURL: URL, name: String) -> Project {
        pendingServerProjectIds.remove(
            ScopedSessionID(serverId: selectedServerId, id: id)
        )
        if let index = projects.firstIndex(where: { $0.serverId == selectedServerId && $0.id == id }) {
            projects[index].isArchived = false
            persistProjects()
            return projects[index]
        }
        var project = Project.fromFolder(folderURL, serverId: selectedServerId)
        project.id = id
        project.name = name
        project.locations = project.locations.map { location in
            var updated = location
            updated.projectId = id
            return updated
        }
        projects.append(project)
        persistProjects()
        return project
    }

    public func archive(_ project: Project) {
        setArchived(true, for: project)
    }

    public func unarchive(_ project: Project) {
        setArchived(false, for: project)
    }

    public func removeProject(_ project: Project) {
        pendingServerProjectIds.remove(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        pendingDeletedProjectIds.insert(
            ScopedSessionID(serverId: project.serverId, id: project.id)
        )
        let removedSessionIDs =
            sessions
            .filter { $0.serverId == project.serverId && $0.projectId == project.id }
            .map(\.id)
        pendingServerSessionIds.subtract(
            removedSessionIDs.map {
                ScopedSessionID(serverId: project.serverId, id: $0)
            })
        pendingArchivedSessionIds.subtract(
            removedSessionIDs.map {
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
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return }
        if serverClient != nil, session.serverId == selectedServerId {
            pendingArchivedSessionIds.insert(
                ScopedSessionID(serverId: session.serverId, id: session.id)
            )
        }
        sessions[index].isArchived = true
        // Stamped locally so the row lands at the top of the archived list
        // immediately, instead of waiting for the server's own timestamp to
        // arrive on the next refresh. The server value overwrites this on
        // merge; the two differ only by the round-trip.
        sessions[index].archivedAt = Date()
        persistSessions()
        syncSession(sessions[index])
    }

    /// Restores an archived session to the active list.
    ///
    /// Clearing the pending marker is mandatory, not tidiness: `mergeSessions`
    /// forces `isArchived = true` on any remote row still listed there, so a
    /// leftover marker would pin the chat archived forever — it would pop back
    /// out of the sidebar on the very next server refresh.
    public func unarchiveSession(_ session: ChatSession) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == session.serverId && $0.id == session.id
            })
        else { return }
        pendingArchivedSessionIds.remove(
            ScopedSessionID(serverId: session.serverId, id: session.id)
        )
        sessions[index].isArchived = false
        sessions[index].archivedAt = nil
        persistSessions()
        syncSession(sessions[index])
    }

    /// Archived chats belonging to a project, newest archive first.
    public func archivedSessions(in project: Project) -> [ChatSession] {
        sessions
            .filter { session in
                session.projectId == project.id
                    && session.serverId == selectedServerId
                    && session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted(by: Self.archivedOrdering)
    }

    /// Every archived chat on the selected machine, newest archive first.
    ///
    /// Deliberately not derived from `activeProjects`: that list drops an
    /// imported project once its last active chat is archived, which would
    /// make the chat the user just archived disappear from the archive too.
    public var archivedSessions: [ChatSession] {
        sessions
            .filter { session in
                session.serverId == selectedServerId
                    && session.isArchived
                    && (session.origin == .codevisor || showsImportedSessions)
            }
            .sorted(by: Self.archivedOrdering)
    }

    /// Orders by archive recency, falling back to activity for rows archived
    /// before `archivedAt` existed so they sort last rather than first.
    private static func archivedOrdering(_ left: ChatSession, _ right: ChatSession) -> Bool {
        let leftStamp = left.archivedAt ?? left.updatedAt ?? left.createdAt
        let rightStamp = right.archivedAt ?? right.updatedAt ?? right.createdAt
        return leftStamp > rightStamp
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

    /// Shares read state through the server. The network request always carries
    /// the exact revision this client saw, so a delayed request cannot consume
    /// attention created after it was sent.
    public func markSessionRead(
        _ sessionId: UUID,
        serverId: String,
        throughSequence: Int? = nil
    ) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        let before = sessions[index]
        let rendered = min(
            max(0, throughSequence ?? before.latestAttentionSequence),
            before.latestAttentionSequence
        )
        // Focus-read fires continuously while a chat stays focused; repeated
        // triggers with nothing unseen must not spam the server.
        guard
            before.unreadCount > 0 || before.hasUnreadError
                || rendered > before.lastSeenAttentionSequence
        else { return }
        sessions[index].lastSeenAttentionSequence = max(
            sessions[index].lastSeenAttentionSequence,
            rendered
        )
        sessions[index].unreadCount = max(
            0,
            sessions[index].latestAttentionSequence - sessions[index].lastSeenAttentionSequence
        )
        if sessions[index].unreadCount == 0 {
            sessions[index].hasUnreadError = false
            if sessions[index].actionRequired {
                sessions[index].sidebarState = .waitingForUser
            } else if sessions[index].sidebarState != .inProgress {
                sessions[index].sidebarState = .idle
            }
        }
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .localMarkRead)
        guard let serverClient, serverId == selectedServerId else { return }
        Task {
            do {
                if let remote = try await serverClient.markSessionRead(
                    id: sessionId,
                    throughSequence: rendered
                ) {
                    applyAttention(remote, serverId: serverId)
                }
            } catch {
                Log.sync.error(
                    "Failed to mark session \(sessionId.uuidString, privacy: .public) read: \(String(describing: error), privacy: .public)"
                )
                await refreshFromServer()
            }
        }
    }

    public func markSessionUnread(_ sessionId: UUID, serverId: String) {
        guard
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == sessionId
            })
        else { return }
        let before = sessions[index]
        sessions[index].unreadCount = max(1, sessions[index].unreadCount)
        if sessions[index].sidebarState == .idle {
            sessions[index].sidebarState = .unread
        }
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .localMarkUnread)
        guard let serverClient, serverId == selectedServerId else { return }
        Task {
            do {
                if let remote = try await serverClient.markSessionUnread(id: sessionId) {
                    applyAttention(remote, serverId: serverId)
                }
            } catch {
                Log.sync.error(
                    "Failed to mark session \(sessionId.uuidString, privacy: .public) unread: \(String(describing: error), privacy: .public)"
                )
                await refreshFromServer()
            }
        }
    }

    private func applyAttention(_ remote: ServerSession, serverId: String) {
        guard let mapped = try? remote.chatSession(serverId: serverId),
            let id = UUID(uuidString: remote.id),
            let index = sessions.firstIndex(where: {
                $0.serverId == serverId && $0.id == id
            })
        else { return }
        guard !attentionIsNewer(sessions[index], than: mapped) else { return }
        let before = sessions[index]
        copyAttention(from: mapped, to: &sessions[index])
        persistSessions()
        emitAttentionTransition(old: before, new: sessions[index], origin: .snapshot)
    }

    private func emitAttentionTransition(
        old: ChatSession?,
        new: ChatSession,
        origin: SessionAttentionTransition.Origin
    ) {
        let oldSummary = old.map(SessionAttentionSummary.init)
        let newSummary = SessionAttentionSummary(new)
        guard oldSummary != newSummary else { return }
        onAttentionTransition?(
            SessionAttentionTransition(
                sessionId: new.id,
                serverId: new.serverId,
                old: oldSummary,
                new: newSummary,
                origin: origin
            ))
    }

    func emitAttentionTransitions(
        from previous: [ChatSession],
        to next: [ChatSession],
        origin: SessionAttentionTransition.Origin
    ) {
        for session in next {
            let old = previous.first { $0.serverId == session.serverId && $0.id == session.id }
            emitAttentionTransition(old: old, new: session, origin: origin)
        }
    }

    private func attentionIsNewer(_ lhs: ChatSession, than rhs: ChatSession) -> Bool {
        if lhs.latestAttentionSequence != rhs.latestAttentionSequence {
            return lhs.latestAttentionSequence > rhs.latestAttentionSequence
        }
        if lhs.lastSeenAttentionSequence != rhs.lastSeenAttentionSequence {
            return lhs.lastSeenAttentionSequence > rhs.lastSeenAttentionSequence
        }
        return lhs.sidebarStateChangedAt > rhs.sidebarStateChangedAt
    }

    private func copyAttention(from source: ChatSession, to destination: inout ChatSession) {
        destination.sidebarState = source.sidebarState
        destination.sidebarStateChangedAt = source.sidebarStateChangedAt
        destination.latestAttentionSequence = source.latestAttentionSequence
        destination.lastSeenAttentionSequence = source.lastSeenAttentionSequence
        destination.unreadCount = source.unreadCount
        destination.hasUnreadError = source.hasUnreadError
        destination.actionRequired = source.actionRequired
        destination.actionRequiredKind = source.actionRequiredKind
        destination.pendingPlanApproval = source.pendingPlanApproval
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
            if let knownIndex = sessions.firstIndex(where: {
                $0.serverId == serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }) {
                reconcileImportedActivity(item, at: knownIndex)
                continue
            }
            let project = findOrCreateProject(
                folderURL: URL(fileURLWithPath: item.info.cwd),
                serverId: serverId
            )
            let timestamp = Self.importTimestamp(item.info.updatedAt)
            sessions.append(
                ChatSession(
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
    /// folder), merging newer activity into known harness-session records.
    /// Sessions inherit the project's server, not the currently selected one:
    /// the user may confirm a pending import after switching machines.
    public func importSessions(_ imported: [ImportedSession], into project: Project) {
        var didChange = false
        for item in imported {
            if let knownIndex = sessions.firstIndex(where: {
                $0.serverId == project.serverId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }) {
                didChange = reconcileImportedActivity(item, at: knownIndex) || didChange
                continue
            }
            let timestamp = Self.importTimestamp(item.info.updatedAt)
            sessions.append(
                ChatSession(
                    projectId: project.id,
                    serverId: project.serverId,
                    harnessId: item.harnessId,
                    agentSessionId: item.info.sessionId,
                    title: item.info.title ?? "Session",
                    origin: .imported,
                    createdAt: timestamp ?? Date(),
                    updatedAt: timestamp
                ))
            didChange = true
        }
        guard didChange else { return }
        persistSessions()
        syncAllToServer()
    }

    /// Native-session discovery is also our source of truth for activity that
    /// happened outside this app. Never roll a cached/server timestamp back,
    /// and leave user-edited metadata (especially the title) alone.
    @discardableResult
    private func reconcileImportedActivity(_ item: ImportedSession, at index: Int) -> Bool {
        guard let discoveredAt = Self.importTimestamp(item.info.updatedAt) else {
            return false
        }
        let cachedAt = sessions[index].updatedAt ?? sessions[index].createdAt
        guard discoveredAt > cachedAt else { return false }
        sessions[index].updatedAt = discoveredAt
        return true
    }

    private static func importTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalImportTimestampFormatter.date(from: value)
            ?? wholeSecondImportTimestampFormatter.date(from: value)
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
        guard
            let index = projects.firstIndex(where: {
                $0.serverId == project.serverId && $0.id == project.id
            })
        else { return }
        projects[index].isArchived = archived
        persistProjects()
        syncProject(projects[index])
    }

    func persistProjects() {
        projectRepository.save(projects)
    }

    func persistSessions() {
        sessionRepository.save(sessions)
    }

    private func refreshFromServerIfConfigured() {
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
        do {
            try await migrateLegacyCacheIfNeeded(serverId: serverId, client: serverClient)
            let prepared = try await fetchSnapshot(serverId: serverId, client: serverClient)
            // The user switched machines while the fetch was in flight: drop
            // the stale response. The newly selected machine triggers its own
            // refresh, and this one would merge (and persist) another
            // machine's projects into the wrong sidebar.
            guard serverId == selectedServerId else { return .superseded }
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
        guard
            let update = await ServerNavigationSnapshotBuilder.sessionUpdate(
                from: event,
                serverId: serverId
            )
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

    /// Mirrors a record to the server it belongs to. The client at hand is the
    /// currently selected machine's, so records from another machine are NOT
    /// pushed here.
    private func syncProject(_ project: Project) {
        guard let serverClient, project.serverId == selectedServerId else { return }
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

    private func syncSession(_ session: ChatSession) {
        // No harness gate: eagerly created chats (workspace "New Chat"
        // tabs) have no harness until their first send, and MUST still
        // reach the server — an unsynced row is dropped by the next
        // authoritative refresh once its pending marker is gone.
        guard let serverClient,
            session.serverId == selectedServerId
        else { return }
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
                    .bulkSyncFailed,
                    title: "Couldn't Sync to the Server",
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
            .serverDeleteFailed,
            title: "Couldn't Delete on the Server",
            message: "It may reappear the next time the list refreshes."
        )
    }
}
