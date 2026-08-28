import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionSnapshot: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var pendingPlanApproval: Bool = false
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var goal: SessionGoal?
    public var sessionPlan: Plan?
}

public struct TranscriptHistoryPage: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest? = nil
    public var pendingPlanApproval: Bool = false
    public var backgroundTasks: [BackgroundTaskInfo]? = nil
    public var goal: SessionGoal? = nil
    public var sessionPlan: Plan? = nil
    public var usage: SessionUsage? = nil
}

public enum SessionTurnInitiator: String, Equatable, Sendable {
    case user
    case agent
}

public enum SessionRuntimeState: String, Equatable, Sendable {
    case running
    case idle
    case requiresAction = "requires_action"
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
    case update(SessionUpdate)
    /// A persisted user message. Carried outside `SessionUpdate` because the
    /// ACP update type cannot carry attachments.
    case userMessage(id: String?, text: String, attachments: [Attachment])
    /// The server-owned identity of the assistant transcript item for a newly
    /// started turn. Live rows adopt this before they settle so their identity
    /// matches snapshots and unread attention targets.
    case assistantItemStarted(UUID)
    /// Server-finalized assistant Markdown plus immutable promoted artifacts.
    case assistantFinalized(markdown: String, messageId: String?, attachments: [Attachment])
    case queueUpdated([ServerPromptQueueItem])
    /// A turn ended. `stopDetail` is a short human-readable reason present only
    /// when the ending was abnormal (error / limit / refusal / gave-up
    /// truncation); the client renders it as a per-turn line. `chatItemId` is
    /// the server-owned identity of the assistant item this turn belongs to —
    /// the same routing the server projection uses — so the closure lands on
    /// that bubble even when it is no longer the active one.
    case finished(
        StopReason,
        stopDetail: String?,
        stopKind: String? = nil,
        retryable: Bool = false,
        initiatedBy: SessionTurnInitiator = .user,
        chatItemId: UUID? = nil
    )
    /// A transient failure is being retried; the turn stays alive. Drives the
    /// visible reconnecting status, with progress when the harness provides it.
    case retrying(RetryStatus)
    /// The server is holding this session's prompts while its harness
    /// updates; `waiting: false` releases the marker. Replaceable: the
    /// latest event wins.
    case updateGate(waiting: Bool, harnessName: String)
    case failed(String, retryable: Bool = false, chatItemId: UUID? = nil)
    /// The harness rejected its credentials. Kept distinct from generic
    /// failures so clients can offer the relevant authentication settings.
    case authenticationRequired(String)
    /// Full replace-on-update snapshot of the agent's in-flight background
    /// tasks (backgrounded shells, subagents). Empty means none pending.
    case backgroundTasks([BackgroundTaskInfo])
    /// Claude's main turn-loop state. `idle` is paired with the background-task
    /// snapshot; detached terminal processes do not prevent quiescence.
    case runtimeState(SessionRuntimeState)
    /// Durable form of Codex's synthetic post-plan approval prompt.
    case planApprovalRequired(Bool)
    /// The harness's selected model declined the request and the turn was
    /// re-run on a fallback model. The swap is sticky for the session, so this
    /// is session-level state rather than a per-turn line.
    case modelFallback(SessionModelFallback)
}

/// A refusal-driven model swap reported by the harness: the selected model's
/// safety classifiers declined the request and another model served it.
public struct SessionModelFallback: Sendable, Equatable {
    /// Raw model identifiers as reported by the harness. Display names are
    /// resolved against the live model option, which may no longer list the
    /// original — hence raw values here rather than presentation strings.
    public var originalModel: String
    public var fallbackModel: String
    /// Refusal category (`cyber`, `bio`, …). An open string on the wire: new
    /// categories ship ahead of schema updates, so this is never parsed.
    public var category: String?

    public init(originalModel: String, fallbackModel: String, category: String? = nil) {
        self.originalModel = originalModel
        self.fallbackModel = fallbackModel
        self.category = category
    }
}

/// One in-flight background task owned by the agent process, from the
/// `session.updated` `backgroundTasks` snapshot payload.
public struct BackgroundTaskInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var description: String
    public var status: String
    public var taskType: String
    public var toolUseId: String?
    /// Set when the task's process streams through a server-owned terminal.
    /// Clients attach with the regular terminal API (`sessionId: terminalKey`,
    /// `attachOnly: true`) and render the task as a live terminal tab instead
    /// of the "Waiting on…" indicator.
    public var terminalKey: String?
    /// The terminal is a read-only mirror: input and kill are unavailable
    /// while the task runs (codex owns its command executions).
    public var readOnly: Bool?

    public init(
        id: String,
        description: String,
        status: String,
        taskType: String,
        toolUseId: String? = nil,
        terminalKey: String? = nil,
        readOnly: Bool? = nil
    ) {
        self.id = id
        self.description = description
        self.status = status
        self.taskType = taskType
        self.toolUseId = toolUseId
        self.terminalKey = terminalKey
        self.readOnly = readOnly
    }
}

public extension ServerAttachmentRef {
    var attachment: Attachment {
        Attachment(
            fileId: fileId,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            kind: kind == .image ? .image : .file
        )
    }
}

public extension Attachment {
    var serverRef: ServerAttachmentRef {
        ServerAttachmentRef(
            fileId: fileId,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            kind: kind == .image ? .image : .file
        )
    }
}
