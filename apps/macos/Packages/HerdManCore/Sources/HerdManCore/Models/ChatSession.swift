import Foundation

/// Where a session came from.
public enum SessionOrigin: String, Sendable, Codable, Equatable {
    /// Created inside HerdMan.
    case herdman
    /// Discovered in the harness via `session/list` (e.g. made in the CLI).
    case imported
}

/// HerdMan's metadata overlay for a session. The harness is the source of truth
/// for the transcript (restored via `session/load`); this stores only what
/// HerdMan needs: the link to the agent session, grouping, archive state, and a
/// cached title.
public struct ChatSession: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var projectId: UUID
    /// The HerdMan server that owns this session. Legacy/local sessions default
    /// to "local"; remote servers provide their configured server id.
    public var serverId: String
    /// The harness this session belongs to (e.g. "claude-code", "codex").
    public var harnessId: String
    /// The harness account/profile pinned to this session.
    public var harnessAccountId: String?
    /// The agent-side session id used to resume via `session/load`. Nil until a
    /// brand-new session has been created with the agent.
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    /// Set when the session runs in a git worktree instead of the project
    /// folder. The worktree lives at ~/herdman/{projectId}/{worktreeName} on
    /// the session's server.
    public var worktreeName: String?
    /// The server-resolved working directory for the session (project folder
    /// or worktree path). Nil for drafts that haven't been synced yet.
    public var cwd: String?
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        serverId: String = "local",
        harnessId: String = "",
        harnessAccountId: String? = nil,
        agentSessionId: String? = nil,
        title: String = "New Session",
        origin: SessionOrigin = .herdman,
        isArchived: Bool = false,
        worktreeName: String? = nil,
        cwd: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.serverId = serverId
        self.harnessId = harnessId
        self.harnessAccountId = harnessAccountId
        self.agentSessionId = agentSessionId
        self.title = title
        self.origin = origin
        self.isArchived = isArchived
        self.worktreeName = worktreeName
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum Keys: String, CodingKey {
        case id, projectId, serverId, harnessId, harnessAccountId, agentSessionId, title, origin, isArchived
        case worktreeName, cwd, createdAt, updatedAt
        /// Pre-rename persisted sessions used this key for `projectId`.
        case workspaceId
    }

    // Custom decoding tolerates older persisted sessions missing newer fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId) {
            self.projectId = projectId
        } else {
            projectId = try container.decode(UUID.self, forKey: .workspaceId)
        }
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
        harnessId = try container.decodeIfPresent(String.self, forKey: .harnessId) ?? ""
        harnessAccountId = try container.decodeIfPresent(String.self, forKey: .harnessAccountId)
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Session"
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .herdman
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        worktreeName = try container.decodeIfPresent(String.self, forKey: .worktreeName)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(harnessId, forKey: .harnessId)
        try container.encodeIfPresent(harnessAccountId, forKey: .harnessAccountId)
        try container.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try container.encode(title, forKey: .title)
        try container.encode(origin, forKey: .origin)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(worktreeName, forKey: .worktreeName)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
