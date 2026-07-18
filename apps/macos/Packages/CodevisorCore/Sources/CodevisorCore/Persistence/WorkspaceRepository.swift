//  Workspace persistence + the sessions→workspaces backfill.
//
//  Workspaces are the persistence root for pane layout (center split tree +
//  bottom panel). The backfill is incremental and idempotent: "ensure a
//  workspace exists for this session" runs whenever a session is opened, so
//  existing chats gain owning workspaces lazily per machine as their
//  sessions load — never touching server-side session data, only
//  referencing it. Legacy per-session pane-group states migrate into the
//  created workspace on first ensure.

import Foundation

public protocol WorkspaceRepository: Sendable {
    func loadAll() -> [Workspace]
    func workspace(id: UUID) -> Workspace?
    /// The workspace owning the chat pane for this session, if any.
    func workspaceId(forSession sessionId: UUID) -> UUID?
    func save(_ workspace: Workspace)
    func delete(id: UUID)
    /// Returns the workspace owning this session's chat, creating it from
    /// the seed (and any legacy per-session pane-group states) on first call.
    func ensureWorkspace(
        for seed: WorkspaceSessionSeed,
        legacyGroups: (any PaneGroupRepository)?
    ) -> Workspace
}

/// Everything the backfill needs to know about a session to give it a
/// workspace. Deliberately a plain bag: Core never sees the app's session
/// types.
public struct WorkspaceSessionSeed: Sendable {
    public let sessionId: UUID
    public let title: String
    public let serverId: String
    public let projectId: UUID
    /// The session's working directory (worktree or project folder).
    public let rootDirectory: String?

    public init(
        sessionId: UUID,
        title: String,
        serverId: String,
        projectId: UUID,
        rootDirectory: String?
    ) {
        self.sessionId = sessionId
        self.title = title
        self.serverId = serverId
        self.projectId = projectId
        self.rootDirectory = rootDirectory
    }
}

/// File/in-memory backed workspace store. One payload under a single key:
/// a version marker, the workspaces, and a session→workspace index (how
/// "by chat" routes to the owning workspace).
public final class DefaultWorkspaceRepository: WorkspaceRepository, @unchecked Sendable {
    private struct Payload: Codable {
        var version: Int
        var workspaces: [Workspace]
        var sessionIndex: [UUID: UUID]

        static let empty = Payload(version: 1, workspaces: [], sessionIndex: [:])
    }

    private let store: any PersistenceStore
    private let key = "workspaces"
    private let lock = NSLock()
    private var cache: Payload?

    public init(store: any PersistenceStore) {
        self.store = store
    }

    public func loadAll() -> [Workspace] {
        payload().workspaces
    }

    public func workspace(id: UUID) -> Workspace? {
        payload().workspaces.first { $0.id == id }
    }

    public func workspaceId(forSession sessionId: UUID) -> UUID? {
        payload().sessionIndex[sessionId]
    }

    public func save(_ workspace: Workspace) {
        var payload = payload()
        if let index = payload.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            payload.workspaces[index] = workspace
        } else {
            payload.workspaces.append(workspace)
        }
        // The index only GROWS on save: a chat whose tab was closed (its
        // session archived) keeps routing to the workspace it lived in —
        // dropping the entry would make ensureWorkspace mint a duplicate
        // workspace next time that session renders. Entries die with their
        // workspace (see delete).
        for sessionId in workspace.chatSessionIds {
            payload.sessionIndex[sessionId] = workspace.id
        }
        persist(payload)
    }

    public func delete(id: UUID) {
        var payload = payload()
        payload.workspaces.removeAll { $0.id == id }
        payload.sessionIndex = payload.sessionIndex.filter { $0.value != id }
        persist(payload)
    }

    /// While the workspace keeps its automatic name it tracks the session's
    /// title; a nil root fills in once the session's directory resolves.
    public func ensureWorkspace(
        for seed: WorkspaceSessionSeed,
        legacyGroups: (any PaneGroupRepository)?
    ) -> Workspace {
        if let id = workspaceId(forSession: seed.sessionId), var existing = workspace(id: id) {
            var changed = false
            if !existing.hasCustomName, !seed.title.isEmpty, existing.name != seed.title {
                existing.name = seed.title
                changed = true
            }
            if existing.rootDirectory == nil, let root = seed.rootDirectory {
                existing.rootDirectory = root
                changed = true
            }
            if changed { save(existing) }
            return existing
        }

        // Migrate the session's pre-workspace pane state, tagging its chat
        // pane with the session it references.
        var center = legacyGroups?.load(sessionId: seed.sessionId, placement: .center)
            ?? .centerInitial(sessionId: seed.sessionId)
        for index in center.panes.indices where center.panes[index].kind == .chat {
            if center.panes[index].chatSessionId == nil {
                center.panes[index].chatSessionId = seed.sessionId
            }
        }
        let bottom = legacyGroups?.load(sessionId: seed.sessionId, placement: .bottom)
            ?? .initial(sessionId: seed.sessionId)

        let workspace = Workspace(
            name: seed.title.isEmpty ? "Workspace" : seed.title,
            rootDirectory: seed.rootDirectory,
            serverId: seed.serverId,
            projectId: seed.projectId,
            centerTree: .leaf(center),
            bottomGroup: bottom
        )
        save(workspace)
        return workspace
    }

    private func payload() -> Payload {
        if let cached = lock.withLock({ cache }) { return cached }
        var loaded: Payload
        if let data = store.loadData(forKey: key) {
            do {
                loaded = try JSONDecoder().decode(Payload.self, from: data)
            } catch {
                handleCorruptPayload(store: store, key: key, data: data, error: error)
                loaded = .empty
            }
        } else {
            loaded = .empty
        }
        // Load-time healing: drop empty groups persisted by an interrupted
        // drop (see `prunedEmptyGroups`). Runs once per launch, before the
        // cache exists, so it can never race an in-session drop's transient
        // empty group.
        for index in loaded.workspaces.indices {
            if let pruned = loaded.workspaces[index].centerTree.prunedEmptyGroups,
               pruned != loaded.workspaces[index].centerTree {
                loaded.workspaces[index].centerTree = pruned
            }
        }
        lock.withLock { if cache == nil { cache = loaded } }
        return loaded
    }

    private func persist(_ payload: Payload) {
        lock.withLock { cache = payload }
        do {
            try store.saveData(JSONEncoder().encode(payload), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// Bridges a workspace's storage into the `PaneGroupRepository` interface
/// `PaneGroupModel` speaks, so group models stay workspace-agnostic:
/// `.bottom` maps to the workspace's bottom panel, `.center` to a specific
/// leaf of the center tree.
public final class WorkspacePaneGroupRepository: PaneGroupRepository, @unchecked Sendable {
    private let workspaceId: UUID
    /// The center leaf this repository reads/writes. Bottom ignores it.
    private let groupId: UUID?
    private let repository: any WorkspaceRepository

    public init(workspaceId: UUID, groupId: UUID?, repository: any WorkspaceRepository) {
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.repository = repository
    }

    public func load(sessionId: UUID, placement: PaneGroupPlacement) -> PaneGroupState? {
        guard let workspace = repository.workspace(id: workspaceId) else { return nil }
        switch placement {
        case .bottom:
            return workspace.bottomGroup
        case .center:
            guard let groupId else { return workspace.centerTree.allGroups.first?.state }
            return workspace.centerTree.group(id: groupId)
        }
    }

    public func save(_ state: PaneGroupState, sessionId: UUID, placement: PaneGroupPlacement) {
        guard var workspace = repository.workspace(id: workspaceId) else { return }
        switch placement {
        case .bottom:
            workspace.bottomGroup = state
        case .center:
            let targetId = groupId ?? workspace.centerTree.allGroups.first?.id
            guard let targetId else { return }
            workspace.centerTree = workspace.centerTree.updatingGroup(id: targetId) { _ in state }
        }
        repository.save(workspace)
    }
}
