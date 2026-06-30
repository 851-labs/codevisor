import Foundation

/// The lifecycle status of a tool call.
public enum ToolCallStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

/// A categorization of the kind of operation a tool performs.
public enum ToolKind: String, Sendable, Codable, Equatable, CaseIterable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode = "switch_mode"
    case other

    /// Decodes leniently so unknown kinds map to `.other`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolKind(rawValue: raw) ?? .other
    }
}

/// A file location referenced by a tool call.
public struct ToolCallLocation: Sendable, Codable, Equatable {
    public var path: String
    public var line: UInt32?

    public init(path: String, line: UInt32? = nil) {
        self.path = path
        self.line = line
    }
}

/// Content produced by a tool call. Discriminated by `type`.
public enum ToolCallContent: Sendable, Codable, Equatable {
    case content(ContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)

    private enum Keys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                path: try container.decode(String.self, forKey: .path),
                oldText: try container.decodeIfPresent(String.self, forKey: .oldText),
                newText: try container.decode(String.self, forKey: .newText)
            )
        case "terminal":
            self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown tool call content type: \(type)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .content(block):
            try container.encode("content", forKey: .type)
            try container.encode(block, forKey: .content)
        case let .diff(path, oldText, newText):
            try container.encode("diff", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(oldText, forKey: .oldText)
            try container.encode(newText, forKey: .newText)
        case let .terminal(terminalId):
            try container.encode("terminal", forKey: .type)
            try container.encode(terminalId, forKey: .terminalId)
        }
    }
}

/// A complete tool call as first reported via a `tool_call` session update.
public struct ToolCall: Sendable, Codable, Equatable, Identifiable {
    public var toolCallId: String
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public var id: String { toolCallId }

    public init(
        toolCallId: String,
        title: String,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

/// A partial update to an in-flight tool call. All fields except the id are optional.
public struct ToolCallUpdate: Sendable, Codable, Equatable {
    public var toolCallId: String
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

public extension ToolCall {
    /// Applies a `ToolCallUpdate`, returning a new merged tool call. Only fields
    /// present in the update overwrite existing values.
    func applying(_ update: ToolCallUpdate) -> ToolCall {
        var result = self
        if let title = update.title { result.title = title }
        if let kind = update.kind { result.kind = kind }
        if let status = update.status { result.status = status }
        if let content = update.content { result.content = content }
        if let locations = update.locations { result.locations = locations }
        if let rawInput = update.rawInput { result.rawInput = rawInput }
        if let rawOutput = update.rawOutput { result.rawOutput = rawOutput }
        return result
    }
}

public extension ToolCallUpdate {
    /// Builds a `ToolCall` from an update, supplying defaults for required fields.
    func asToolCall() -> ToolCall {
        ToolCall(
            toolCallId: toolCallId,
            title: title ?? "",
            kind: kind,
            status: status,
            content: content,
            locations: locations,
            rawInput: rawInput,
            rawOutput: rawOutput
        )
    }
}
