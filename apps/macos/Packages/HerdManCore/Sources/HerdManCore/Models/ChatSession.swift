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
    public var workspaceId: UUID
    /// The HerdMan server that owns this session. Legacy/local sessions default
    /// to "local"; remote servers provide their configured server id.
    public var serverId: String
    /// The harness this session belongs to (e.g. "claude-code", "codex").
    public var harnessId: String
    /// The agent-side session id used to resume via `session/load`. Nil until a
    /// brand-new session has been created with the agent.
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        workspaceId: UUID,
        serverId: String = "local",
        harnessId: String = "",
        agentSessionId: String? = nil,
        title: String = "New Session",
        origin: SessionOrigin = .herdman,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.serverId = serverId
        self.harnessId = harnessId
        self.agentSessionId = agentSessionId
        self.title = title
        self.origin = origin
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum Keys: String, CodingKey {
        case id, workspaceId, serverId, harnessId, agentSessionId, title, origin, isArchived, createdAt, updatedAt
    }

    // Custom decoding tolerates older persisted sessions missing newer fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workspaceId = try container.decode(UUID.self, forKey: .workspaceId)
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
        harnessId = try container.decodeIfPresent(String.self, forKey: .harnessId) ?? ""
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Session"
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .herdman
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}
