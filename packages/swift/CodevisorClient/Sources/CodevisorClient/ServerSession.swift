import ACPKit
import CodevisorProtocol
import Foundation

/// The three wire states of a goal's token budget on update, mirroring the
/// codex double-option: omit the key to keep the current budget, send an
/// explicit `null` to clear it, or send a positive number to set it.
public enum TokenBudgetUpdate: Sendable, Equatable {
    case keep
    case clear
    case set(Int)
}

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public var harnesses: [ServerHarnessCapability]

    public init(
        harnesses: [ServerHarnessCapability]
    ) {
        self.harnesses = harnesses
    }
}

public struct ServerSessionRuntimeMetadata: Codable, Equatable, Sendable {
    public var sessionId: String
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]
    public var supportsGoals: Bool?
}

public struct ServerPromptAccepted: Decodable, Equatable, Sendable {
    public var accepted: Bool
    public var sessionId: String
    public var queueItemId: String?

    public init(
        accepted: Bool,
        sessionId: String,
        queueItemId: String? = nil
    ) {
        self.accepted = accepted
        self.sessionId = sessionId
        self.queueItemId = queueItemId
    }
}

public struct ServerPromptQueueItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public var attachments: [ServerAttachmentRef]?

    public init(
        id: String, sessionId: String, text: String, createdAt: String, updatedAt: String,
        attachments: [ServerAttachmentRef]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
    }
}

public enum ServerAttachmentKind: String, Codable, Equatable, Sendable {
    case image
    case file
}

/// A reference to an uploaded file (`POST /v1/files`); bytes are fetched via
/// `GET /v1/files/:id`.
public struct ServerAttachmentRef: Codable, Identifiable, Equatable, Sendable {
    public var fileId: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var kind: ServerAttachmentKind

    public var id: String { fileId }

    public init(fileId: String, name: String, mimeType: String, sizeBytes: Int, kind: ServerAttachmentKind) {
        self.fileId = fileId
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

public struct ServerFileMetadata: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var sha256: String
    public var kind: ServerAttachmentKind
    public var createdAt: String

    public var attachmentRef: ServerAttachmentRef {
        ServerAttachmentRef(fileId: id, name: name, mimeType: mimeType, sizeBytes: sizeBytes, kind: kind)
    }
}

public struct ServerSessionUsage: Decodable, Equatable, Sendable {
    public var used: Double?
    public var size: Double?
    public var inputTokens: Double?
    public var cachedInputTokens: Double?
    public var outputTokens: Double?
    public var reasoningOutputTokens: Double?
    public var totalTokens: Double?
    public var costAmount: Double?
    public var costCurrency: String?
    public var costKind: String?

    public var sessionUsage: SessionUsage {
        SessionUsage(
            used: used.map(UInt64.init),
            size: size.map(UInt64.init),
            inputTokens: inputTokens.map(UInt64.init),
            cachedInputTokens: cachedInputTokens.map(UInt64.init),
            outputTokens: outputTokens.map(UInt64.init),
            reasoningOutputTokens: reasoningOutputTokens.map(UInt64.init),
            totalTokens: totalTokens.map(UInt64.init),
            cost: costAmount.map {
                SessionCost(
                    amount: $0,
                    currency: costCurrency ?? "USD",
                    kind: costKind.flatMap(SessionCost.Kind.init(rawValue:))
                )
            }
        )
    }
}

public struct ServerHarnessUsageWindow: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var durationMinutes: Double?
    public var resetsAt: String?
}

public struct ServerHarnessUsageCredits: Decodable, Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var balance: String?
}

public struct ServerHarnessUsageLimits: Decodable, Equatable, Sendable {
    public var state: String
    public var harnessId: String
    public var accountId: String?
    public var accountLabel: String?
    public var accountEmail: String?
    public var plan: String?
    public var windows: [ServerHarnessUsageWindow]
    public var credits: ServerHarnessUsageCredits?
    public var detail: String?
    public var fetchedAt: String
}

public struct ServerSession: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var harnessId: String
    public var harnessAccountId: String?
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    /// Optional so a server predating archive timestamps still decodes.
    public var archivedAt: String? = nil
    public var worktreeName: String?
    public var workspaceId: String? = nil
    public var cwd: String?
    public var configSelections: [String: String]? = nil
    public var createdAt: String
    public var updatedAt: String?
    public var sidebarState: SessionSidebarState? = nil
    public var sidebarStateChangedAt: String? = nil
    public var usage: ServerSessionUsage?
    public var latestAttentionSequence: Int? = nil
    public var lastSeenAttentionSequence: Int? = nil
    public var unreadCount: Int? = nil
    public var hasUnreadError: Bool? = nil
    public var actionRequired: Bool? = nil
    public var actionRequiredKind: String? = nil
    public var pendingPlanApproval: Bool? = nil

    /// Maps a server-owned record into the client's machine namespace.
    ///
    /// A remote server commonly reports its own internal id (for example,
    /// `"local"`), while the client addresses that same machine through a
    /// connection-scoped id such as `"cloud:<machine-id>"`. Requiring the
    /// scope here prevents a response from silently moving a live session into
    /// the wrong client namespace.
    public func chatSession(serverId scopedServerId: String) throws -> ChatSession {
        guard let uuid = UUID(uuidString: id) else {
            throw CodevisorServerClientError.invalidUUID(id)
        }
        guard let projectUUID = UUID(uuidString: projectId) else {
            throw CodevisorServerClientError.invalidUUID(projectId)
        }
        return ChatSession(
            id: uuid,
            projectId: projectUUID,
            serverId: scopedServerId,
            harnessId: harnessId,
            harnessAccountId: harnessAccountId,
            // The server stores "" for a deferred (not-yet-created) agent;
            // the app's "no agent yet" checks all use nil — normalize at
            // the boundary so both spellings mean the same thing.
            agentSessionId: agentSessionId.flatMap { $0.isEmpty ? nil : $0 },
            title: title,
            origin: origin,
            isArchived: isArchived,
            // Tolerated rather than thrown on: an unparseable archive stamp
            // should cost ordering precision, not drop the whole chat.
            archivedAt: archivedAt.flatMap { try? ServerDateCoding.date(from: $0) },
            worktreeName: worktreeName,
            cwd: cwd,
            configSelections: configSelections,
            createdAt: try ServerDateCoding.date(from: createdAt),
            updatedAt: try updatedAt.map(ServerDateCoding.date),
            sidebarState: sidebarState ?? .idle,
            sidebarStateChangedAt: sidebarStateChangedAt.flatMap {
                try? ServerDateCoding.date(from: $0)
            }
                ?? updatedAt.flatMap {
                    try? ServerDateCoding.date(from: $0)
                },
            latestAttentionSequence: latestAttentionSequence ?? 0,
            lastSeenAttentionSequence: lastSeenAttentionSequence ?? 0,
            unreadCount: unreadCount ?? 0,
            hasUnreadError: hasUnreadError ?? false,
            actionRequired: actionRequired ?? false,
            actionRequiredKind: actionRequiredKind,
            pendingPlanApproval: pendingPlanApproval ?? false
        )
    }

    public init(
        id: String,
        projectId: String,
        serverId: String,
        harnessId: String,
        harnessAccountId: String? = nil,
        agentSessionId: String? = nil,
        title: String,
        origin: SessionOrigin,
        isArchived: Bool,
        archivedAt: String? = nil,
        worktreeName: String? = nil,
        workspaceId: String? = nil,
        cwd: String? = nil,
        configSelections: [String: String]? = nil,
        createdAt: String,
        updatedAt: String? = nil,
        sidebarState: SessionSidebarState? = nil,
        sidebarStateChangedAt: String? = nil,
        usage: ServerSessionUsage? = nil,
        latestAttentionSequence: Int? = nil,
        lastSeenAttentionSequence: Int? = nil,
        unreadCount: Int? = nil,
        hasUnreadError: Bool? = nil,
        actionRequired: Bool? = nil,
        actionRequiredKind: String? = nil,
        pendingPlanApproval: Bool? = nil
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
        self.archivedAt = archivedAt
        self.worktreeName = worktreeName
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.configSelections = configSelections
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sidebarState = sidebarState
        self.sidebarStateChangedAt = sidebarStateChangedAt
        self.usage = usage
        self.latestAttentionSequence = latestAttentionSequence
        self.lastSeenAttentionSequence = lastSeenAttentionSequence
        self.unreadCount = unreadCount
        self.hasUnreadError = hasUnreadError
        self.actionRequired = actionRequired
        self.actionRequiredKind = actionRequiredKind
        self.pendingPlanApproval = pendingPlanApproval
    }
}

public enum ServerConversationRole: String, Decodable, Equatable, Sendable {
    case user
    case assistant
    case system
}

public struct ServerConversationItem: Decodable, Equatable, Sendable {
    public var id: String
    public var role: ServerConversationRole
    public var messageId: String?
    public var text: String
    public var createdAt: String
    public var isGenerating: Bool
    public var attachments: [ServerAttachmentRef]? = nil

    public init(
        id: String,
        role: ServerConversationRole,
        messageId: String? = nil,
        text: String,
        createdAt: String,
        isGenerating: Bool,
        attachments: [ServerAttachmentRef]? = nil
    ) {
        self.id = id
        self.role = role
        self.messageId = messageId
        self.text = text
        self.createdAt = createdAt
        self.isGenerating = isGenerating
        self.attachments = attachments
    }
}

public struct ServerSessionDetail: Decodable, Equatable, Sendable {
    public var session: ServerSession
    public var conversation: [ServerConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var pendingPlanApproval: Bool
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var goal: SessionGoal?

    public init(
        session: ServerSession,
        conversation: [ServerConversationItem],
        promptQueue: [ServerPromptQueueItem] = [],
        eventCursor: Int,
        pendingQuestion: QuestionRequest? = nil,
        pendingPlanApproval: Bool = false,
        backgroundTasks: [BackgroundTaskInfo]? = nil,
        goal: SessionGoal? = nil
    ) {
        self.session = session
        self.conversation = conversation
        self.promptQueue = promptQueue
        self.eventCursor = eventCursor
        self.pendingQuestion = pendingQuestion
        self.pendingPlanApproval = pendingPlanApproval
        self.backgroundTasks = backgroundTasks
        self.goal = goal
    }

    enum CodingKeys: String, CodingKey {
        case session
        case conversation
        case promptQueue
        case eventCursor
        case pendingQuestion, pendingPlanApproval
        case backgroundTasks
        case goal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(ServerSession.self, forKey: .session)
        conversation = try container.decode([ServerConversationItem].self, forKey: .conversation)
        promptQueue = try container.decodeIfPresent([ServerPromptQueueItem].self, forKey: .promptQueue) ?? []
        eventCursor = try container.decode(Int.self, forKey: .eventCursor)
        pendingQuestion = try container.decodeIfPresent(QuestionRequest.self, forKey: .pendingQuestion)
        pendingPlanApproval = try container.decodeIfPresent(Bool.self, forKey: .pendingPlanApproval) ?? false
        backgroundTasks = try container.decodeIfPresent([BackgroundTaskInfo].self, forKey: .backgroundTasks)
        goal = try container.decodeIfPresent(SessionGoal.self, forKey: .goal)
    }
}

public struct ServerTranscriptItem: Decodable, Equatable, Sendable {
    public enum Role: String, Decodable, Equatable, Sendable {
        case user
        case assistant
    }

    public var id: String
    public var sessionId: String
    public var sequence: Int
    public var role: Role
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public var isGenerating: Bool
    public var hasDetails: Bool
    public var turnId: String?
    public var startedAt: String?
    public var endedAt: String?
    public var stopReason: String?
    public var stopDetail: String?
    public var stopKind: String?
    public var retryable: Bool?
    public var planDocument: String?
    public var attachments: [ServerAttachmentRef]?
    /// Provider message id of the still-streaming answer candidate. Present
    /// only while the item is generating so a mid-stream restore can share
    /// identity with the live deltas that continue the same span.
    public var messageId: String?
    /// Provider-asserted finality of the candidate. `nil` remains optimistic
    /// and must not settle the worked section during a mid-stream restore.
    public var phase: MessagePhase?
    public var revision: Int

    public init(
        id: String,
        sessionId: String,
        sequence: Int,
        role: Role,
        text: String,
        createdAt: String,
        updatedAt: String,
        isGenerating: Bool,
        hasDetails: Bool,
        turnId: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        stopReason: String? = nil,
        stopDetail: String? = nil,
        stopKind: String? = nil,
        retryable: Bool? = nil,
        planDocument: String? = nil,
        attachments: [ServerAttachmentRef]? = nil,
        messageId: String? = nil,
        phase: MessagePhase? = nil,
        revision: Int
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sequence = sequence
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isGenerating = isGenerating
        self.hasDetails = hasDetails
        self.turnId = turnId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stopReason = stopReason
        self.stopDetail = stopDetail
        self.stopKind = stopKind
        self.retryable = retryable
        self.planDocument = planDocument
        self.attachments = attachments
        self.messageId = messageId
        self.phase = phase
        self.revision = revision
    }
}

public struct ServerTranscriptPage: Decodable, Equatable, Sendable {
    public var items: [ServerTranscriptItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var pendingPlanApproval: Bool
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var goal: SessionGoal?
    public var usage: ServerSessionUsage?

    public init(
        items: [ServerTranscriptItem],
        nextBefore: String? = nil,
        hasMore: Bool,
        eventCursor: Int,
        pendingQuestion: QuestionRequest? = nil,
        pendingPlanApproval: Bool = false,
        backgroundTasks: [BackgroundTaskInfo]? = nil,
        goal: SessionGoal? = nil,
        usage: ServerSessionUsage? = nil
    ) {
        self.items = items
        self.nextBefore = nextBefore
        self.hasMore = hasMore
        self.eventCursor = eventCursor
        self.pendingQuestion = pendingQuestion
        self.pendingPlanApproval = pendingPlanApproval
        self.backgroundTasks = backgroundTasks
        self.goal = goal
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case items
        case nextBefore
        case hasMore
        case eventCursor
        case pendingQuestion
        case pendingPlanApproval
        case backgroundTasks
        case goal
        case usage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ServerTranscriptItem].self, forKey: .items)
        nextBefore = try container.decodeIfPresent(String.self, forKey: .nextBefore)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        eventCursor = try container.decode(Int.self, forKey: .eventCursor)
        pendingQuestion = try container.decodeIfPresent(QuestionRequest.self, forKey: .pendingQuestion)
        pendingPlanApproval =
            try container.decodeIfPresent(Bool.self, forKey: .pendingPlanApproval) ?? false
        backgroundTasks =
            try container.decodeIfPresent([BackgroundTaskInfo].self, forKey: .backgroundTasks)
        goal = try container.decodeIfPresent(SessionGoal.self, forKey: .goal)
        usage = try container.decodeIfPresent(ServerSessionUsage.self, forKey: .usage)
    }
}

/// Response of the combined `POST /v1/sessions/:id/open`: the authoritative
/// session record plus the first transcript page, fetched in one round-trip
/// so a chat can paint its history without waiting on discrete calls.
public struct ServerSessionOpenResponse: Decodable, Sendable {
    public var session: ServerSession
    public var transcript: ServerTranscriptPage
}

public struct ServerTranscriptItemDetails: Decodable, Equatable, Sendable {
    public var itemId: String
    public var revision: Int
    public var events: [ServerEventEnvelope]

    public init(
        itemId: String,
        revision: Int,
        events: [ServerEventEnvelope]
    ) {
        self.itemId = itemId
        self.revision = revision
        self.events = events
    }
}
