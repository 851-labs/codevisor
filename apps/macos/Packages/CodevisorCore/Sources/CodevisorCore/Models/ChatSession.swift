import Foundation

/// Where a session came from.
public enum SessionOrigin: String, Sendable, Codable, Equatable {
    /// Created inside Codevisor.
    case codevisor
    /// Discovered in the harness via `session/list` (e.g. made in the CLI).
    case imported

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "codevisor", "herdman": self = .codevisor
        case "imported": self = .imported
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown session origin: \(value)")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Codevisor's metadata overlay for a session. The harness is the source of truth
/// for the transcript (restored via `session/load`); this stores only what
/// Codevisor needs: the link to the agent session, grouping, archive state, and a
/// cached title.
public struct ChatSession: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var projectId: UUID
    /// The Codevisor server that owns this session. Legacy/local sessions default
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
    /// folder. The worktree lives at ~/codevisor/{projectId}/{worktreeName} on
    /// the session's server.
    public var worktreeName: String?
    /// The server-resolved working directory for the session (project folder
    /// or worktree path). Nil for drafts that haven't been synced yet.
    public var cwd: String?
    /// Last configuration values accepted for this chat. Option definitions
    /// come from the harness cache/live runtime; these values let the composer
    /// paint the chat's actual previous selections while reconnecting.
    public var configSelections: [String: String]?
    public var createdAt: Date
    public var updatedAt: Date?
    /// Server-owned attention state shared by every client of this session.
    public var latestAttentionSequence: Int
    public var lastSeenAttentionSequence: Int
    public var unreadCount: Int
    public var hasUnreadError: Bool
    public var actionRequired: Bool
    public var actionRequiredKind: String?
    public var pendingPlanApproval: Bool

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        serverId: String = "local",
        harnessId: String = "",
        harnessAccountId: String? = nil,
        agentSessionId: String? = nil,
        title: String = "New Session",
        origin: SessionOrigin = .codevisor,
        isArchived: Bool = false,
        worktreeName: String? = nil,
        cwd: String? = nil,
        configSelections: [String: String]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        latestAttentionSequence: Int = 0,
        lastSeenAttentionSequence: Int = 0,
        unreadCount: Int = 0,
        hasUnreadError: Bool = false,
        actionRequired: Bool = false,
        actionRequiredKind: String? = nil,
        pendingPlanApproval: Bool = false
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
        self.configSelections = configSelections
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.latestAttentionSequence = latestAttentionSequence
        self.lastSeenAttentionSequence = lastSeenAttentionSequence
        self.unreadCount = unreadCount
        self.hasUnreadError = hasUnreadError
        self.actionRequired = actionRequired
        self.actionRequiredKind = actionRequiredKind
        self.pendingPlanApproval = pendingPlanApproval
    }

    private enum Keys: String, CodingKey {
        case id, projectId, serverId, harnessId, harnessAccountId, agentSessionId, title, origin, isArchived
        case worktreeName, cwd, configSelections, createdAt, updatedAt
        case latestAttentionSequence, lastSeenAttentionSequence, unreadCount, hasUnreadError
        case actionRequired, actionRequiredKind, pendingPlanApproval
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
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .codevisor
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        worktreeName = try container.decodeIfPresent(String.self, forKey: .worktreeName)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        configSelections = try container.decodeIfPresent([String: String].self, forKey: .configSelections)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        latestAttentionSequence = try container.decodeIfPresent(Int.self, forKey: .latestAttentionSequence) ?? 0
        lastSeenAttentionSequence = try container.decodeIfPresent(Int.self, forKey: .lastSeenAttentionSequence) ?? 0
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        hasUnreadError = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadError) ?? false
        actionRequired = try container.decodeIfPresent(Bool.self, forKey: .actionRequired) ?? false
        actionRequiredKind = try container.decodeIfPresent(String.self, forKey: .actionRequiredKind)
        pendingPlanApproval = try container.decodeIfPresent(Bool.self, forKey: .pendingPlanApproval) ?? false
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
        try container.encodeIfPresent(configSelections, forKey: .configSelections)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(latestAttentionSequence, forKey: .latestAttentionSequence)
        try container.encode(lastSeenAttentionSequence, forKey: .lastSeenAttentionSequence)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(hasUnreadError, forKey: .hasUnreadError)
        try container.encode(actionRequired, forKey: .actionRequired)
        try container.encodeIfPresent(actionRequiredKind, forKey: .actionRequiredKind)
        try container.encode(pendingPlanApproval, forKey: .pendingPlanApproval)
    }
}
