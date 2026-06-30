import Foundation

/// `session/load` request params. Resuming a session replays its history as
/// `session/update` notifications, then returns the current modes/config.
public struct LoadSessionRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var mcpServers: [McpServer]
    public var additionalDirectories: [String]?

    public init(sessionId: String, cwd: String, mcpServers: [McpServer] = [], additionalDirectories: [String]? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
    }
}

/// `session/load` response.
public struct LoadSessionResponse: Sendable, Codable, Equatable {
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?

    public init(modes: SessionModeState? = nil, configOptions: [SessionConfigOption]? = nil) {
        self.modes = modes
        self.configOptions = configOptions
    }
}

/// A summary of an agent-side session, as returned by `session/list`.
public struct SessionInfo: Sendable, Codable, Equatable, Identifiable {
    public var sessionId: String
    public var cwd: String
    public var title: String?
    public var updatedAt: String?

    public var id: String { sessionId }

    public init(sessionId: String, cwd: String, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// `session/list` request params.
public struct ListSessionsRequest: Sendable, Codable, Equatable {
    public var cwd: String?
    public var cursor: String?

    public init(cwd: String? = nil, cursor: String? = nil) {
        self.cwd = cwd
        self.cursor = cursor
    }
}

/// `session/list` response.
public struct ListSessionsResponse: Sendable, Codable, Equatable {
    public var sessions: [SessionInfo]
    public var nextCursor: String?

    public init(sessions: [SessionInfo], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// `session/delete` request params.
public struct DeleteSessionRequest: Sendable, Codable, Equatable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
