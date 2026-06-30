import Foundation

/// A streaming update emitted by the agent during a prompt turn.
///
/// Discriminated by the `sessionUpdate` field. For `tool_call` and
/// `tool_call_update` the payload fields are inline alongside the discriminator.
public enum SessionUpdate: Sendable, Codable, Equatable {
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case userMessageChunk(ContentBlock)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case currentModeUpdate(currentModeId: String)
    case configOptionUpdate([SessionConfigOption])

    private enum Keys: String, CodingKey {
        case sessionUpdate, content, entries, availableCommands, currentModeId, configOptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "agent_message_chunk":
            self = .agentMessageChunk(try container.decode(ContentBlock.self, forKey: .content))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try container.decode(ContentBlock.self, forKey: .content))
        case "user_message_chunk":
            self = .userMessageChunk(try container.decode(ContentBlock.self, forKey: .content))
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
        case let .agentMessageChunk(content):
            try container.encode("agent_message_chunk", forKey: .sessionUpdate)
            try container.encode(content, forKey: .content)
        case let .agentThoughtChunk(content):
            try container.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try container.encode(content, forKey: .content)
        case let .userMessageChunk(content):
            try container.encode("user_message_chunk", forKey: .sessionUpdate)
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
        }
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
