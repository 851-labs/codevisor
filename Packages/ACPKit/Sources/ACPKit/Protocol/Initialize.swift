import Foundation

/// Identifies a client or agent implementation.
public struct Implementation: Sendable, Codable, Equatable {
    public var name: String
    public var version: String
    public var title: String?

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

/// File system capabilities advertised by the client.
public struct FileSystemCapabilities: Sendable, Codable, Equatable {
    public var readTextFile: Bool
    public var writeTextFile: Bool

    public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

/// Capabilities advertised by the client during initialization.
public struct ClientCapabilities: Sendable, Codable, Equatable {
    public var fs: FileSystemCapabilities?
    public var terminal: Bool?

    public init(fs: FileSystemCapabilities? = nil, terminal: Bool? = nil) {
        self.fs = fs
        self.terminal = terminal
    }
}

/// Prompt content capabilities advertised by the agent.
public struct PromptCapabilities: Sendable, Codable, Equatable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?

    public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
    }
}

/// Which session-management operations the agent supports. Each key is present
/// (as an empty object) when supported.
public struct SessionCapabilities: Sendable, Codable, Equatable {
    public var list: Bool
    public var resume: Bool
    public var delete: Bool
    public var close: Bool
    public var fork: Bool

    private enum Keys: String, CodingKey {
        case list, resume, delete, close, fork
    }

    public init(list: Bool = false, resume: Bool = false, delete: Bool = false, close: Bool = false, fork: Bool = false) {
        self.list = list
        self.resume = resume
        self.delete = delete
        self.close = close
        self.fork = fork
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        list = container.contains(.list)
        resume = container.contains(.resume)
        delete = container.contains(.delete)
        close = container.contains(.close)
        fork = container.contains(.fork)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        let empty = [String: String]()
        if list { try container.encode(empty, forKey: .list) }
        if resume { try container.encode(empty, forKey: .resume) }
        if delete { try container.encode(empty, forKey: .delete) }
        if close { try container.encode(empty, forKey: .close) }
        if fork { try container.encode(empty, forKey: .fork) }
    }
}

/// Capabilities advertised by the agent during initialization.
public struct AgentCapabilities: Sendable, Codable, Equatable {
    public var loadSession: Bool?
    public var promptCapabilities: PromptCapabilities?
    public var sessionCapabilities: SessionCapabilities?

    public init(
        loadSession: Bool? = nil,
        promptCapabilities: PromptCapabilities? = nil,
        sessionCapabilities: SessionCapabilities? = nil
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.sessionCapabilities = sessionCapabilities
    }
}

/// An authentication method advertised by the agent.
public struct AuthMethod: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// `initialize` request params.
public struct InitializeRequest: Sendable, Codable, Equatable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities?
    public var clientInfo: Implementation?

    public init(
        protocolVersion: Int,
        clientCapabilities: ClientCapabilities? = nil,
        clientInfo: Implementation? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

/// `initialize` response.
public struct InitializeResponse: Sendable, Codable, Equatable {
    public var protocolVersion: Int
    public var agentCapabilities: AgentCapabilities?
    public var authMethods: [AuthMethod]?
    public var agentInfo: Implementation?

    public init(
        protocolVersion: Int,
        agentCapabilities: AgentCapabilities? = nil,
        authMethods: [AuthMethod]? = nil,
        agentInfo: Implementation? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
        self.agentInfo = agentInfo
    }
}

/// `authenticate` request params.
public struct AuthenticateRequest: Sendable, Codable, Equatable {
    public var methodId: String

    public init(methodId: String) {
        self.methodId = methodId
    }
}

public extension Int {
    /// The ACP protocol version implemented by this SDK.
    static let acpProtocolVersion = 1
}
