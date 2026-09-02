import Foundation

/// An HTTP header passed to an MCP server.
public struct HTTPHeader: Sendable, Codable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An environment variable passed to a stdio MCP server.
public struct EnvVariable: Sendable, Codable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An MCP server the agent should connect to for the session. Discriminated by `type`.
public enum McpServer: Sendable, Codable, Equatable {
    case stdio(name: String, command: String, args: [String], env: [EnvVariable])
    case http(name: String, url: String, headers: [HTTPHeader])
    case sse(name: String, url: String, headers: [HTTPHeader])

    private enum Keys: String, CodingKey {
        case type, name, command, args, env, url, headers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        // stdio is the default when `type` is absent.
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "stdio"
        let name = try container.decode(String.self, forKey: .name)
        switch type {
        case "stdio":
            self = .stdio(
                name: name,
                command: try container.decode(String.self, forKey: .command),
                args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
                env: try container.decodeIfPresent([EnvVariable].self, forKey: .env) ?? []
            )
        case "http":
            self = .http(
                name: name,
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? []
            )
        case "sse":
            self = .sse(
                name: name,
                url: try container.decode(String.self, forKey: .url),
                headers: try container.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown MCP server type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .stdio(name, command, args, env):
            try container.encode("stdio", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encode(env, forKey: .env)
        case let .http(name, url, headers):
            try container.encode("http", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        case let .sse(name, url, headers):
            try container.encode("sse", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
            try container.encode(headers, forKey: .headers)
        }
    }
}

/// A session interaction mode.
public struct SessionMode: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    /// Codevisor's harness-independent mode id (`readOnly`, `ask`, `autoEdit`,
    /// `fullAccess`, `plan`) when the native mode maps onto one; nil for
    /// agent-defined modes that stay native-only.
    public var canonicalId: String?

    public init(id: String, name: String, description: String? = nil, canonicalId: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.canonicalId = canonicalId
    }
}

/// The set of available modes and the current selection.
public struct SessionModeState: Sendable, Codable, Equatable {
    public var currentModeId: String
    public var availableModes: [SessionMode]

    public init(currentModeId: String, availableModes: [SessionMode]) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }
}

/// `session/new` request params.
public struct NewSessionRequest: Sendable, Codable, Equatable {
    public var cwd: String
    public var mcpServers: [McpServer]
    public var additionalDirectories: [String]?

    public init(cwd: String, mcpServers: [McpServer] = [], additionalDirectories: [String]? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
    }
}

/// `session/new` response.
public struct NewSessionResponse: Sendable, Codable, Equatable {
    public var sessionId: String
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?

    public init(
        sessionId: String,
        modes: SessionModeState? = nil,
        configOptions: [SessionConfigOption]? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
    }
}

/// `session/set_mode` request params.
public struct SetSessionModeRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var modeId: String

    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

/// The reason a prompt turn ended.
public enum StopReason: String, Sendable, Codable, Equatable, CaseIterable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

/// `session/prompt` request params.
public struct PromptRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var prompt: [ContentBlock]

    public init(sessionId: String, prompt: [ContentBlock]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

/// `session/prompt` response.
public struct PromptResponse: Sendable, Codable, Equatable {
    public var stopReason: StopReason

    public init(stopReason: StopReason) {
        self.stopReason = stopReason
    }
}

/// `session/cancel` notification params.
public struct CancelNotification: Sendable, Codable, Equatable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
