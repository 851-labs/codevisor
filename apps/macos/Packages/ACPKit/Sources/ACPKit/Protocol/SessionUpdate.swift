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

/// Lifecycle of a persistent session goal, mirroring codex thread-goal
/// statuses. `active` goals auto-continue turns agent-side.
public enum GoalStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete
}

/// A persistent per-session objective (codex "goal mode"). Snapshots are
/// idempotent full state: consumers replace, never accumulate.
public struct SessionGoal: Sendable, Codable, Equatable {
    public var objective: String
    public var status: GoalStatus
    /// Token budget for the goal; nil when unbounded.
    public var tokenBudget: Int?
    public var tokensUsed: Int
    public var timeUsedSeconds: Int
    public var createdAt: String
    public var updatedAt: String

    public init(
        objective: String,
        status: GoalStatus,
        tokenBudget: Int? = nil,
        tokensUsed: Int = 0,
        timeUsedSeconds: Int = 0,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One option of an agent-asked question.
public struct QuestionOption: Sendable, Codable, Equatable, Identifiable {
    public var label: String
    public var description: String?

    public var id: String { label }

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One question inside a blocking question request.
public struct QuestionSpec: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var header: String?
    public var question: String
    public var options: [QuestionOption]
    public var multiSelect: Bool?
    public var allowsOther: Bool
    public var isSecret: Bool?

    public init(
        id: String,
        header: String? = nil,
        question: String,
        options: [QuestionOption] = [],
        multiSelect: Bool? = nil,
        allowsOther: Bool = true,
        isSecret: Bool? = nil
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.allowsOther = allowsOther
        self.isSecret = isSecret
    }
}

/// A blocking agent question: the turn holds until the client answers via
/// the answer endpoint (or the provider auto-resolves it).
public struct QuestionRequest: Sendable, Codable, Equatable {
    public var questionId: String
    /// Context line shown above the questions (e.g. an MCP server's
    /// elicitation message).
    public var message: String?
    public var questions: [QuestionSpec]
    public var autoResolutionMs: Int?

    public init(
        questionId: String,
        message: String? = nil,
        questions: [QuestionSpec],
        autoResolutionMs: Int? = nil
    ) {
        self.questionId = questionId
        self.message = message
        self.questions = questions
        self.autoResolutionMs = autoResolutionMs
    }
}

public extension QuestionRequest {
    /// The stable question id + accept label the agent-runtime tags onto
    /// Claude's ExitPlanMode approval (see `claude.ts`). Kept in sync there so
    /// the client recognizes an accepted plan and can leave plan mode as it
    /// answers.
    static let exitPlanModeId = "exit_plan_mode"
    static let implementPlanLabel = "Implement plan"
    static let keepPlanningLabel = "Keep planning"
}

public enum QuestionOutcome: String, Sendable, Codable, Equatable {
    case answered
    case cancelled
    case autoResolved
}

/// The user's reply to one question: chosen option labels (or the free-text
/// entry) plus an optional note typed alongside a selection.
public struct QuestionAnswerEntry: Sendable, Codable, Equatable {
    public var answers: [String]
    public var note: String?

    public init(answers: [String], note: String? = nil) {
        self.answers = answers
        self.note = note
    }
}

/// Terminal event for a question request; pairs with the `question` event by
/// `questionId` and carries everything needed to render the answered card.
public struct QuestionResolution: Sendable, Codable, Equatable {
    public var questionId: String
    public var outcome: QuestionOutcome
    public var questions: [QuestionSpec]
    public var answers: [String: QuestionAnswerEntry]?

    public init(
        questionId: String,
        outcome: QuestionOutcome,
        questions: [QuestionSpec],
        answers: [String: QuestionAnswerEntry]? = nil
    ) {
        self.questionId = questionId
        self.outcome = outcome
        self.questions = questions
        self.answers = answers
    }
}

/// Finality of an agent message span, when the provider can tell.
///
/// `final` is the turn's terminal answer — clients may style it as the final
/// response from its first streamed chunk. `commentary` is mid-turn narration
/// that never becomes the answer. Absent means unknown: render optimistically
/// (the last text span is the candidate answer). A zero-length chunk carrying
/// a phase retro-tags an already-streamed span by `messageId`.
public enum MessagePhase: String, Sendable, Codable, Equatable {
    case commentary
    case final
}

/// A streaming update emitted by the agent during a prompt turn.
///
/// Discriminated by the `sessionUpdate` field. For `tool_call` and
/// `tool_call_update` the payload fields are inline alongside the discriminator.
public enum SessionUpdate: Sendable, Codable, Equatable {
    case agentMessageChunk(
        ContentBlock, messageId: String?, parentToolCallId: String?, phase: MessagePhase?
    )
    case agentThoughtChunk(ContentBlock, messageId: String?, parentToolCallId: String?)
    case userMessageChunk(ContentBlock, messageId: String?)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case currentModeUpdate(currentModeId: String)
    case configOptionUpdate([SessionConfigOption])
    case usageUpdate(SessionUsage)
    case goalUpdate(SessionGoal)
    case goalCleared
    /// A free-form markdown plan the agent proposes before implementing
    /// (Claude plan mode's ExitPlanMode, codex plan-mode plan items) —
    /// distinct from the `plan` step checklist. Replaces per turn.
    case planDocument(markdown: String)
    /// A blocking agent question awaiting the user's answer.
    case question(QuestionRequest)
    /// Terminal pair for a `question` event, matched by questionId.
    case questionResolved(QuestionResolution)

    private enum Keys: String, CodingKey {
        case sessionUpdate, messageId, parentToolCallId, phase, content, entries, availableCommands
        case currentModeId, configOptions
        case used, size, cost, goal, markdown
        case questionId, message, questions, autoResolutionMs, outcome, answers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "agent_message_chunk":
            self = .agentMessageChunk(
                try container.decode(ContentBlock.self, forKey: .content),
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                parentToolCallId: try container.decodeIfPresent(String.self, forKey: .parentToolCallId),
                // Lenient: an unknown phase value decodes as nil, not an error.
                phase: ((try? container.decodeIfPresent(String.self, forKey: .phase)) ?? nil)
                    .flatMap(MessagePhase.init(rawValue:))
            )
        case "agent_thought_chunk":
            self = .agentThoughtChunk(
                try container.decode(ContentBlock.self, forKey: .content),
                messageId: try container.decodeIfPresent(String.self, forKey: .messageId),
                parentToolCallId: try container.decodeIfPresent(String.self, forKey: .parentToolCallId)
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
        case "goal_update":
            self = .goalUpdate(try container.decode(SessionGoal.self, forKey: .goal))
        case "goal_cleared":
            self = .goalCleared
        case "plan_document":
            self = .planDocument(markdown: try container.decode(String.self, forKey: .markdown))
        case "question":
            self = .question(QuestionRequest(
                questionId: try container.decode(String.self, forKey: .questionId),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                questions: try container.decode([QuestionSpec].self, forKey: .questions),
                autoResolutionMs: try container.decodeIfPresent(Int.self, forKey: .autoResolutionMs)
            ))
        case "question_resolved":
            self = .questionResolved(QuestionResolution(
                questionId: try container.decode(String.self, forKey: .questionId),
                outcome: try container.decode(QuestionOutcome.self, forKey: .outcome),
                questions: try container.decode([QuestionSpec].self, forKey: .questions),
                answers: try container.decodeIfPresent([String: QuestionAnswerEntry].self, forKey: .answers)
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
        case let .agentMessageChunk(content, messageId, parentToolCallId, phase):
            try container.encode("agent_message_chunk", forKey: .sessionUpdate)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encodeIfPresent(parentToolCallId, forKey: .parentToolCallId)
            try container.encodeIfPresent(phase, forKey: .phase)
            try container.encode(content, forKey: .content)
        case let .agentThoughtChunk(content, messageId, parentToolCallId):
            try container.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try container.encodeIfPresent(messageId, forKey: .messageId)
            try container.encodeIfPresent(parentToolCallId, forKey: .parentToolCallId)
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
        case let .goalUpdate(goal):
            try container.encode("goal_update", forKey: .sessionUpdate)
            try container.encode(goal, forKey: .goal)
        case .goalCleared:
            try container.encode("goal_cleared", forKey: .sessionUpdate)
        case let .planDocument(markdown):
            try container.encode("plan_document", forKey: .sessionUpdate)
            try container.encode(markdown, forKey: .markdown)
        case let .question(request):
            try container.encode("question", forKey: .sessionUpdate)
            try container.encode(request.questionId, forKey: .questionId)
            try container.encodeIfPresent(request.message, forKey: .message)
            try container.encode(request.questions, forKey: .questions)
            try container.encodeIfPresent(request.autoResolutionMs, forKey: .autoResolutionMs)
        case let .questionResolved(resolution):
            try container.encode("question_resolved", forKey: .sessionUpdate)
            try container.encode(resolution.questionId, forKey: .questionId)
            try container.encode(resolution.outcome, forKey: .outcome)
            try container.encode(resolution.questions, forKey: .questions)
            try container.encodeIfPresent(resolution.answers, forKey: .answers)
        }
    }
}

public extension SessionUpdate {
    static func agentMessageChunk(_ content: ContentBlock) -> SessionUpdate {
        .agentMessageChunk(content, messageId: nil, parentToolCallId: nil, phase: nil)
    }

    static func agentMessageChunk(_ content: ContentBlock, messageId: String?) -> SessionUpdate {
        .agentMessageChunk(content, messageId: messageId, parentToolCallId: nil, phase: nil)
    }

    static func agentMessageChunk(
        _ content: ContentBlock, messageId: String?, parentToolCallId: String?
    ) -> SessionUpdate {
        .agentMessageChunk(
            content, messageId: messageId, parentToolCallId: parentToolCallId, phase: nil
        )
    }

    static func agentThoughtChunk(_ content: ContentBlock) -> SessionUpdate {
        .agentThoughtChunk(content, messageId: nil, parentToolCallId: nil)
    }

    static func agentThoughtChunk(_ content: ContentBlock, messageId: String?) -> SessionUpdate {
        .agentThoughtChunk(content, messageId: messageId, parentToolCallId: nil)
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
