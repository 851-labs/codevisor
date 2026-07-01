import Foundation

/// Cumulative cost information for a session (from a `usage_update`).
public struct SessionCost: Sendable, Codable, Equatable {
    /// Total cumulative cost for the session.
    public var amount: Double
    /// ISO 4217 currency code (e.g. "USD").
    public var currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

/// Context-window and cost usage for a session (from a `usage_update`).
public struct SessionUsage: Sendable, Codable, Equatable {
    /// Tokens currently in context.
    public var used: UInt64?
    /// Total context-window size in tokens.
    public var size: UInt64?
    /// Cumulative session cost, if the agent reports it.
    public var cost: SessionCost?

    public init(used: UInt64? = nil, size: UInt64? = nil, cost: SessionCost? = nil) {
        self.used = used
        self.size = size
        self.cost = cost
    }
}

/// A streaming update emitted by the agent during a prompt turn.
///
/// Discriminated by the `sessionUpdate` field. For `tool_call` and
/// `tool_call_update` the payload fields are inline alongside the discriminator.
public enum SessionUpdate: Sendable, Codable, Equatable {
    case agentMessageChunk(ContentBlock, messageId: String?)
    case agentThoughtChunk(ContentBlock, messageId: String?)
    case userMessageChunk(ContentBlock, messageId: String?)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case currentModeUpdate(currentModeId: String)
    case configOptionUpdate([SessionConfigOption])
    case usageUpdate(SessionUsage)

    private enum Keys: String, CodingKey {
        case sessionUpdate, messageId, content, entries, availableCommands, currentModeId, configOptions
        case used, size, cost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "agent_message_chunk":
            self = .agentMessageChunk(
                try container.decode(ContentBlock.self, forKey: .content),
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId)
            )
        case "agent_thought_chunk":
            self = .agentThoughtChunk(
                try container.decode(ContentBlock.self, forKey: .content),
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId)
            )
        case "user_message_chunk":
            self = .userMessageChunk(
                try container.decode(ContentBlock.self, forKey: .content),
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId)
            )
        case "tool_call":
            self = .toolCall(try ToolCall(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(Plan(entries: try container.decode([PlanEntry].self, forKey: .entries)))
        case "available_commands_update":
            self = .availableCommandsUpdate(
                try container.decode([AvailableCommand].self, forKey: .availableCommands)
            )
        case "current_mode_update":
            self = .currentModeUpdate(
                currentModeId: try container.decode(String.self, forKey: .currentModeId)
            )
        case "config_option_update":
            self = .configOptionUpdate(
                try container.decode([SessionConfigOption].self, forKey: .configOptions)
            )
        case "usage_update":
            self = .usageUpdate(SessionUsage(
                used: try container.decodeIfPresent(UInt64.self, forKey: .used),
                size: try container.decodeIfPresent(UInt64.self, forKey: .size),
                cost: try container.decodeIfPresent(SessionCost.self, forKey: .cost)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .sessionUpdate,
                in: container,
                debugDescription: "Unknown session update: \(kind)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .agentMessageChunk(content, messageId):
            try container.encode("agent_message_chunk", forKey: .sessionUpdate)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encode(content, forKey: .content)
        case let .agentThoughtChunk(content, messageId):
            try container.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encode(content, forKey: .content)
        case let .userMessageChunk(content, messageId):
            try container.encode("user_message_chunk", forKey: .sessionUpdate)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encode(content, forKey: .content)
        case let .toolCall(toolCall):
            try container.encode("tool_call", forKey: .sessionUpdate)
            try toolCall.encode(to: encoder)
        case let .toolCallUpdate(update):
            try container.encode("tool_call_update", forKey: .sessionUpdate)
            try update.encode(to: encoder)
        case let .plan(plan):
            try container.encode("plan", forKey: .sessionUpdate)
            try container.encode(plan.entries, forKey: .entries)
        case let .availableCommandsUpdate(commands):
            try container.encode("available_commands_update", forKey: .sessionUpdate)
            try container.encode(commands, forKey: .availableCommands)
        case let .currentModeUpdate(currentModeId):
            try container.encode("current_mode_update", forKey: .sessionUpdate)
            try container.encode(currentModeId, forKey: .currentModeId)
        case let .configOptionUpdate(options):
            try container.encode("config_option_update", forKey: .sessionUpdate)
            try container.encode(options, forKey: .configOptions)
        case let .usageUpdate(usage):
            try container.encode("usage_update", forKey: .sessionUpdate)
            try container.encodeIfPresent(usage.used, forKey: .used)
            try container.encodeIfPresent(usage.size, forKey: .size)
            try container.encodeIfPresent(usage.cost, forKey: .cost)
        }
    }
}

public extension SessionUpdate {
    static func agentMessageChunk(_ content: ContentBlock) -> SessionUpdate {
        .agentMessageChunk(content, messageId: nil)
    }

    static func agentThoughtChunk(_ content: ContentBlock) -> SessionUpdate {
        .agentThoughtChunk(content, messageId: nil)
    }

    static func userMessageChunk(_ content: ContentBlock) -> SessionUpdate {
        .userMessageChunk(content, messageId: nil)
    }
}

/// The params of a `session/update` notification.
public struct SessionNotification: Sendable, Codable, Equatable {
    public var sessionId: String
    public var update: SessionUpdate

    private enum Keys: String, CodingKey {
        case sessionId, update
    }

    public init(sessionId: String, update: SessionUpdate) {
        self.sessionId = sessionId
        self.update = update
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        // The update fields are nested under `update`.
        update = try container.decode(SessionUpdate.self, forKey: .update)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(update, forKey: .update)
    }
}
