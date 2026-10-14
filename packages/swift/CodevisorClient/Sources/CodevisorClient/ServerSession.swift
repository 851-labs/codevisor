import ACPKit
import CodevisorProtocol
import Foundation

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

public struct ServerSessionUsage: Codable, Equatable, Sendable {
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

public struct ServerSession: Codable, Equatable, Sendable {
  public var id: String
  public var projectId: String
  public var serverId: String
  public var harnessId: String
  public var harnessAccountId: String?
  public var agentSessionId: String?
  public var title: String
  public var origin: SessionOrigin
  public var worktreeName: String?
  public var workspaceId: String? = nil
  public var cwd: String?
  public var configSelections: [String: String]? = nil
  public var unavailableConfigSelections: [String: String]? = nil
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
      agentSessionId: agentSessionId.flatMap { $0.isEmpty ? nil : $0 },
      title: title,
      origin: origin,
      worktreeName: worktreeName,
      cwd: cwd,
      configSelections: configSelections,
      unavailableConfigSelections: unavailableConfigSelections,
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
    worktreeName: String? = nil,
    workspaceId: String? = nil,
    cwd: String? = nil,
    configSelections: [String: String]? = nil,
    unavailableConfigSelections: [String: String]? = nil,
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
    self.worktreeName = worktreeName
    self.workspaceId = workspaceId
    self.cwd = cwd
    self.configSelections = configSelections
    self.unavailableConfigSelections = unavailableConfigSelections
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

public struct ServerSessionUpdateGate: Decodable, Equatable, Sendable {
  public var harnessId: String
  public var harnessName: String

  public init(harnessId: String, harnessName: String) {
    self.harnessId = harnessId
    self.harnessName = harnessName
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
  public var planProposedAt: String? = nil
  public var planResumedAt: String? = nil
  public var attachments: [ServerAttachmentRef]?
  public var messageId: String?
  public var phase: MessagePhase?
  public var textGeneration: Int?
  public var textPosition: Int? = nil
  public var textRevision: Int?
  public var textResource: ToolDetailResource?
  public var planResource: ToolDetailResource?
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
    revision: Int,
    textGeneration: Int? = nil, textRevision: Int? = nil,
    textResource: ToolDetailResource? = nil, planResource: ToolDetailResource? = nil
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
    self.textGeneration = textGeneration
    self.textRevision = textRevision
    self.textResource = textResource
    self.planResource = planResource
    self.revision = revision
  }
}

public struct ServerSessionOpenResponse: Decodable, Sendable {
  public var session: ServerSession
  public var transcript: ServerTranscriptPage
  public var runtime: ServerSessionRuntimeMetadata?
}

public struct ServerTranscriptEntry: Decodable, Equatable, Sendable {
  public var key: String
  public var position: Int
  public var revision: Int
  public var payload: JSONValue

  public init(key: String, position: Int, revision: Int, payload: JSONValue) {
    self.key = key
    self.position = position
    self.revision = revision
    self.payload = payload
  }
}

public struct ServerTranscriptItemDetails: Decodable, Equatable, Sendable {
  public var itemId: String
  public var revision: Int
  public var eventCursor: Int
  public var entries: [ServerTranscriptEntry]
  public var nextAfter: String?
  public var previousBefore: String?

  public init(
    itemId: String, revision: Int, eventCursor: Int, entries: [ServerTranscriptEntry], nextAfter: String? = nil,
    previousBefore: String? = nil
  ) {
    self.itemId = itemId
    self.revision = revision
    self.eventCursor = eventCursor
    self.entries = entries
    self.nextAfter = nextAfter
    self.previousBefore = previousBefore
  }
}

public struct ServerTranscriptBodyPage: Decodable, Sendable {
  public var revision: Int
  public var encoding: String
  public var text: String
  public var position: Int
  public var nextPosition: Int?
}
