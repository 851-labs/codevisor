import Foundation
import Observation
import ACPKit

struct TranscriptDetailsCacheEntry {
  let revision: Int
  let turn: AssistantTurn
}

@MainActor
@Observable
public final class SessionModel {
  public private(set) var transcriptProjectionRevision: UInt64 = 0

  public static let initialTranscriptPageSize = 8
  static let olderTranscriptPageSize = 16
  static var cancellationTerminalEventWaitDelay: Duration = .milliseconds(100)
  public internal(set) var settledConversation: [ConversationItem] = [] {
    didSet { transcriptProjectionRevision &+= 1 }
  }
  public internal(set) var activeItem: ConversationItem? {
    didSet {
      activeItemRevision &+= 1
      if activeItem?.id != oldValue?.id, hasActiveItem {
        transcriptProjectionRevision &+= 1
      }
    }
  }
  public private(set) var activeItemRevision: UInt64 = 0
  public internal(set) var hasActiveItem = false {
    didSet {
      if hasActiveItem != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }

  public var conversation: [ConversationItem] {
    if let activeItem {
      return settledConversation + [activeItem]
    }
    return settledConversation
  }
  public internal(set) var isSending = false {
    didSet {
      if isSending != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var isCancelling = false
  public internal(set) var modelFallback: SessionModelFallback?
  public internal(set) var isTakingLongerThanExpected = false
  public internal(set) var connectionRecoveryMessage: String? {
    didSet {
      if connectionRecoveryMessage != oldValue {
        activeItemRevision &+= 1
        transcriptProjectionRevision &+= 1
      }
    }
  }
  @ObservationIgnored var streamSynchronization: SessionStreamSynchronization = .caughtUp
  @ObservationIgnored let streamReconnectNotice: DelayedConnectionNotice
  @ObservationIgnored var connectionRecoveryGeneration: UInt64 = 0
  public internal(set) var queuedPrompts: [ServerPromptQueueItem] = []
  @ObservationIgnored var promptQueueRevision: UInt64 = 0
  @ObservationIgnored var promptQueueLoadTask: Task<Void, Never>?
  public internal(set) var updateGateHarnessName: String? {
    didSet {
      if updateGateHarnessName != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public var composerText: String = ""
  public internal(set) var availableCommands: [AvailableCommand] = []
  public internal(set) var availableSkills: SessionSkills?
  public internal(set) var modeState: SessionModeState?
  public internal(set) var configOptions: [SessionConfigOption]
  @ObservationIgnored var configMutationRevisions: [String: UInt64] = [:]
  @ObservationIgnored var inFlightConfigValues: [String: String] = [:]
  public internal(set) var errorMessage: String? {
    didSet {
      if errorMessage != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var harnessAuthenticationErrorMessage: String?
  public var errorRequiresHarnessAuthentication: Bool {
    errorMessage != nil && harnessAuthenticationErrorMessage == errorMessage
  }
  public internal(set) var usage: SessionUsage?
  public internal(set) var backgroundTasks: [BackgroundTaskInfo] = [] {
    didSet {
      if backgroundTasks != oldValue { transcriptProjectionRevision &+= 1 }
      let ids = runningSubagentSpawnIds(backgroundTasks)
      if ids != runningSubagentToolCallIds {
        runningSubagentToolCallIds = ids
      }
      let runIds = Set(waitingBackgroundTasks.compactMap(\.toolUseId))
      if runIds != runningSubagentRunToolCallIds {
        runningSubagentRunToolCallIds = runIds
      }
    }
  }
  public internal(set) var persistedSetupPhases: [SessionSetupPhase] = [] {
    didSet { if persistedSetupPhases != oldValue { transcriptProjectionRevision &+= 1 } }
  }
  public internal(set) var hasOlderHistory = false
  public internal(set) var isLoadingOlderHistory = false
  @ObservationIgnored var olderHistoryCursor: String?
  @ObservationIgnored var usesPaginatedHistory = false
  @ObservationIgnored var transcriptDetailsCache: [String: TranscriptDetailsCacheEntry] = [:]
  @ObservationIgnored var transcriptDetailLoadTasks: [String: Task<Bool, Never>] = [:]
  @ObservationIgnored var toolOwnerItemIds: [String: UUID] = [:]
  @ObservationIgnored var settledIndexById: [UUID: Int] = [:]

  public var waitingBackgroundTasks: [BackgroundTaskInfo] {
    backgroundTasks.filter { $0.taskType == "subagent" }
  }

  public var isWaitingOnBackgroundTasks: Bool {
    !isSending && !waitingBackgroundTasks.isEmpty
  }

  public private(set) var runningSubagentToolCallIds: Set<String> = []
  public private(set) var runningSubagentRunToolCallIds: Set<String> = []

  public internal(set) var goal: SessionGoal?
  public internal(set) var pendingQuestion: QuestionRequest?
  public internal(set) var pendingPlanApproval = false
  public internal(set) var isResolvingQuestion = false
  public internal(set) var sessionPlan: Plan?

  public var onTurnEnded: (() -> Void)?
  public var onPlanApprovalChanged: ((Bool) -> Void)?
  public var onPromptAccepted: ((_ attachmentCount: Int, _ isQueued: Bool) -> Void)?
  public var onLocalUserMessageAppended: ((UUID) -> Void)?
  public var onQueuedPromptPromoted: ((UUID?) -> Void)?

  @ObservationIgnored public var promptClientId: String?

  let transport: ServerSessionTransport
  private let sessionId: String
  let now: @Sendable () -> Date
  static let stalledTurnQuietInterval: Duration = .seconds(300)
  let quietTurnScheduler: SessionQuietTurnScheduler
  var serverEventCursor: Int?
  var isReplayingHistory = false
  var historicalConfigSelections: [String: String] = [:]

  var consumerTask: Task<Void, Never>?
  @ObservationIgnored var stalledTurnSchedule: SessionQuietTurnCancellation?
  @ObservationIgnored var connectionRecoveryTask: Task<Void, Never>?
  @ObservationIgnored var surfacedConnectionRecoveryError: String?

  let connectionRecoveryScheduler: SessionConnectionRecoveryScheduler
  let connectionRecoveryStatusDelay: Duration
  let connectionRecoveryRetryBaseDelay: Duration
  let connectionRecoveryRetryMaximumDelay: Duration

  @ObservationIgnored nonisolated let pendingEvents = SessionEventBuffer()
  @ObservationIgnored var isFlushScheduled = false
  @ObservationIgnored var scheduledFlushTask: Task<Void, Never>?
  @ObservationIgnored var presentationFrameRequester: (@MainActor () -> Bool)?
  @ObservationIgnored var pendingQueuePromotionIDs: [String: TimeInterval] = [:]
  @ObservationIgnored var pendingOptimisticUserMessageIDs: Set<UUID> = []
  static var eventFlushInterval: Duration = .milliseconds(16)

  static var backgroundEventFlushInterval: Duration = .milliseconds(300)

  @ObservationIgnored var visibleViewCount = 0
  var isViewVisible: Bool { visibleViewCount > 0 }

  @ObservationIgnored var presentationBoundarySleep: @Sendable (Duration) async throws -> Void = {
    try await Task.sleep(for: $0)
  }

  public init(
    serverTransport: ServerSessionTransport,
    sessionId: String,
    modeState: SessionModeState? = nil,
    configOptions: [SessionConfigOption] = [],
    now: @escaping @Sendable () -> Date = { Date() },
    quietTurnScheduler: SessionQuietTurnScheduler = .continuous,
    connectionRecoveryScheduler: SessionConnectionRecoveryScheduler = .continuous,
    connectionRecoveryStatusDelay: Duration = .seconds(5),
    connectionRecoveryRetryBaseDelay: Duration = .milliseconds(500),
    connectionRecoveryRetryMaximumDelay: Duration = .seconds(5)
  ) {
    self.transport = serverTransport
    self.sessionId = sessionId
    self.modeState = modeState
    self.configOptions = configOptions
    self.now = now
    self.quietTurnScheduler = quietTurnScheduler
    self.connectionRecoveryScheduler = connectionRecoveryScheduler
    self.connectionRecoveryStatusDelay = connectionRecoveryStatusDelay
    self.connectionRecoveryRetryBaseDelay = connectionRecoveryRetryBaseDelay
    self.connectionRecoveryRetryMaximumDelay = connectionRecoveryRetryMaximumDelay
    self.streamReconnectNotice = DelayedConnectionNotice(
      delay: connectionRecoveryStatusDelay, now: connectionRecoveryScheduler.now,
      sleep: connectionRecoveryScheduler.sleep)
    streamReconnectNotice.onVisibilityChange = { [weak self] isVisible in
      self?.streamReconnectNoticeChanged(isVisible: isVisible)
    }
  }

  @ObservationIgnored var appliedUpdateCount = 0
}

extension SessionModel {
  func runningSubagentSpawnIds(_ tasks: [BackgroundTaskInfo]) -> Set<String> {
    var ids = Set<String>()
    for task in tasks where task.taskType == "subagent" {
      guard let toolUseId = task.toolUseId else { continue }
      if let call = toolCall(toolUseId), call.kind != .agent,
        let spawn = subagentSpawn(taskId: task.id)
      {
        ids.insert(spawn.toolCallId)
      } else {
        ids.insert(toolUseId)
      }
    }
    return ids
  }

  public var waitingSubagentCalls: [ToolCall] {
    var seen = Set<String>()
    return waitingBackgroundTasks.compactMap { task -> ToolCall? in
      guard let toolUseId = task.toolUseId, let call = toolCall(toolUseId) else { return nil }
      let spawn = call.kind == .agent ? call : subagentSpawn(taskId: task.id)
      guard let spawn, seen.insert(spawn.toolCallId).inserted else { return nil }
      return spawn
    }
  }

  private func toolCall(_ id: String) -> ToolCall? {
    for item in conversation.reversed() {
      guard case let .assistant(message) = item else { continue }
      if let call = message.turn.allToolCalls.first(where: { $0.toolCallId == id }) { return call }
    }
    return nil
  }

  private func subagentSpawn(taskId: String) -> ToolCall? {
    for item in conversation.reversed() {
      guard case let .assistant(message) = item else { continue }
      if let call = message.turn.allToolCalls.first(where: { $0.kind == .agent && $0.subagentTaskId == taskId }) {
        return call
      }
    }
    return nil
  }
}
