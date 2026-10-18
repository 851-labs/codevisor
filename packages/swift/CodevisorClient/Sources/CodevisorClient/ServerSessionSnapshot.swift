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
  public var updateGateHarnessName: String? = nil
}

public struct TranscriptHistoryPage: Equatable, Sendable {
  public var conversation: [ConversationItem]
  public var nextBefore: String?
  public var hasMore: Bool
  public var setupPhases: [SessionSetupPhase] = []
  public var stateUpdates: [SessionUpdate] = []
  public var eventCursor: Int
  public var pendingQuestion: QuestionRequest? = nil
  public var pendingPlanApproval: Bool = false
  public var backgroundTasks: [BackgroundTaskInfo]? = nil
  public var goal: SessionGoal? = nil
  public var skills: SessionSkills? = nil
  public var sessionPlan: Plan? = nil
  public var usage: SessionUsage? = nil
  public var updateGateHarnessName: String? = nil
}

public enum SessionRuntimeState: String, Equatable, Sendable {
  case running
  case idle
  case requiresAction = "requires_action"
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
  case synchronization(SessionStreamSynchronization)
  case update(SessionUpdate)
  case userMessage(id: String?, text: String, attachments: [Attachment])
  case assistantItemStarted(UUID)
  case assistantFinalized(markdown: String, messageId: String?, attachments: [Attachment])
  case queueUpdated([ServerPromptQueueItem])
  case finished(
    StopReason,
    stopDetail: String?,
    stopKind: String? = nil,
    retryable: Bool = false,
    chatItemId: UUID? = nil
  )
  case retrying(RetryStatus)
  case updateGate(waiting: Bool, harnessName: String)
  case failed(String, retryable: Bool = false, chatItemId: UUID? = nil)
  case authenticationRequired(String)
  case backgroundTasks([BackgroundTaskInfo])
  case runtimeState(SessionRuntimeState)
  case planApprovalRequired(Bool)
  case modelFallback(SessionModelFallback)
  case botMessage(ServerBotMessage)
}

public enum SessionStreamSynchronization: String, Equatable, Sendable {
  case reconnecting
  case catchingUp
  case caughtUp
  case cursor
}

public struct SessionModelFallback: Sendable, Equatable {
  public var originalModel: String
  public var fallbackModel: String
  public var category: String?

  public init(originalModel: String, fallbackModel: String, category: String? = nil) {
    self.originalModel = originalModel
    self.fallbackModel = fallbackModel
    self.category = category
  }
}

public struct BackgroundTaskInfo: Sendable, Equatable, Codable, Identifiable {
  public var id: String
  public var description: String
  public var status: String
  public var taskType: String
  public var toolUseId: String?

  public init(
    id: String,
    description: String,
    status: String,
    taskType: String,
    toolUseId: String? = nil
  ) {
    self.id = id
    self.description = description
    self.status = status
    self.taskType = taskType
    self.toolUseId = toolUseId
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
