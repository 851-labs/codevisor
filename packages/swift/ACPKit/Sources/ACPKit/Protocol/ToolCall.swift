import Foundation

/// The lifecycle status of a tool call. Terminal states are `completed`,
/// `failed`, and `cancelled`.
public enum ToolCallStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
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
    /// A web search. Not part of the ACP kind vocabulary — Codevisor's own
    /// extension so clients can phrase these as searches ("Searched the
    /// web") instead of generic fetches.
    case webSearch = "web_search"
    /// A subagent spawn (e.g. Claude's Task tool). Not part of the ACP kind
    /// vocabulary — Codevisor's own extension so clients can render a nested
    /// transcript section for the call.
    case agent
    /// A question the agent asked the user (AskUserQuestion). Not part of the
    /// ACP kind vocabulary — Codevisor synthesizes an answered question into the
    /// transcript as a tool call so it renders as a normal worked-for row.
    case question
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

/// Added/removed line counts for one file touched by a tool call. Values are
/// cumulative for the tool call; each update replaces the previous stats.
public struct ToolCallDiffStat: Sendable, Codable, Equatable {
    public var path: String
    public var added: Int
    public var removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// A value that swallows its own decoding failures, so one unrecognized
/// element can be skipped instead of failing the containing decode (which
/// would drop the whole session update on the floor).
public struct LenientlyDecoded<Wrapped: Decodable>: Decodable {
    public let value: Wrapped?

    public init(from decoder: any Decoder) {
        do {
            value = try Wrapped(from: decoder)
        } catch {
            value = nil
            acpLog.error(
                "Skipped malformed \(String(describing: Wrapped.self), privacy: .public) element: \(String(describing: error), privacy: .public)"
            )
        }
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

private enum ToolCallKeys: String, CodingKey {
    case toolCallId, title, kind, status, content, locations, rawInput, rawOutput, diffStats
    case parentToolCallId
}

/// Shared lenient field decoding for `ToolCall` and `ToolCallUpdate`: an
/// unknown status string becomes nil, and unrecognized content elements are
/// skipped per-element — a newer server must never make the client drop the
/// whole event.
private struct ToolCallFields {
    var title: String?
    var kind: ToolKind?
    var status: ToolCallStatus?
    var content: [ToolCallContent]?
    var locations: [ToolCallLocation]?
    var rawInput: JSONValue?
    var rawOutput: JSONValue?
    var diffStats: [ToolCallDiffStat]?
    var parentToolCallId: String?

    init(from container: KeyedDecodingContainer<ToolCallKeys>) {
        title = Self.lenient(String.self, from: container, forKey: .title)
        kind = Self.lenient(ToolKind.self, from: container, forKey: .kind)
        // Status and content affect turn liveness (a lost terminal status
        // leaves the call spinning forever), so their swallows log at .error.
        do {
            if let raw = try container.decodeIfPresent(String.self, forKey: .status) {
                status = ToolCallStatus(rawValue: raw)
                if status == nil {
                    acpLog.error(
                        "Unknown tool call status \"\(raw, privacy: .public)\" — treating as absent"
                    )
                }
            }
        } catch {
            acpLog.error(
                "Tool call status failed to decode: \(String(describing: error), privacy: .public)"
            )
        }
        do {
            if let elements = try container.decodeIfPresent(
                [LenientlyDecoded<ToolCallContent>].self, forKey: .content)
            {
                content = elements.compactMap(\.value)
            }
        } catch {
            acpLog.error(
                "Tool call content failed to decode: \(String(describing: error), privacy: .public)"
            )
        }
        locations = Self.lenient([ToolCallLocation].self, from: container, forKey: .locations)
        rawInput = Self.lenient(JSONValue.self, from: container, forKey: .rawInput)
        rawOutput = Self.lenient(JSONValue.self, from: container, forKey: .rawOutput)
        diffStats = Self.lenient([ToolCallDiffStat].self, from: container, forKey: .diffStats)
        parentToolCallId = Self.lenient(String.self, from: container, forKey: .parentToolCallId)
    }

    // Decodes an optional field, logging (rather than silently dropping) a
    // value that was present but malformed. Absent keys stay silent.
    private static func lenient<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<ToolCallKeys>,
        forKey key: ToolCallKeys
    ) -> T? {
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            acpLog.debug(
                "Tool call \(key.stringValue, privacy: .public) failed to decode: \(String(describing: error), privacy: .public)"
            )
            return nil
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
    /// Cumulative added/removed line counts per file, streamed while the edit
    /// is being generated by providers that can observe it.
    public var diffStats: [ToolCallDiffStat]?
    /// When set, this call was made by a subagent spawned by the tool call
    /// with that id (e.g. a Claude Task) — clients nest it under the parent.
    public var parentToolCallId: String?

    public var id: String { toolCallId }

    public init(
        toolCallId: String,
        title: String,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        diffStats: [ToolCallDiffStat]? = nil,
        parentToolCallId: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.diffStats = diffStats
        self.parentToolCallId = parentToolCallId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ToolCallKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        let fields = ToolCallFields(from: container)
        title = fields.title ?? ""
        kind = fields.kind
        status = fields.status
        content = fields.content
        locations = fields.locations
        rawInput = fields.rawInput
        rawOutput = fields.rawOutput
        diffStats = fields.diffStats
        parentToolCallId = fields.parentToolCallId
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
    public var diffStats: [ToolCallDiffStat]?
    public var parentToolCallId: String?

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        diffStats: [ToolCallDiffStat]? = nil,
        parentToolCallId: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.diffStats = diffStats
        self.parentToolCallId = parentToolCallId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ToolCallKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        let fields = ToolCallFields(from: container)
        title = fields.title
        kind = fields.kind
        status = fields.status
        content = fields.content
        locations = fields.locations
        rawInput = fields.rawInput
        rawOutput = fields.rawOutput
        diffStats = fields.diffStats
        parentToolCallId = fields.parentToolCallId
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
        if let diffStats = update.diffStats { result.diffStats = diffStats }
        if let parentToolCallId = update.parentToolCallId { result.parentToolCallId = parentToolCallId }
        return result
    }

    /// True once the call has reached a terminal status.
    var isSettled: Bool {
        status == .completed || status == .failed || status == .cancelled
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
            rawOutput: rawOutput,
            diffStats: diffStats,
            parentToolCallId: parentToolCallId
        )
    }
}
