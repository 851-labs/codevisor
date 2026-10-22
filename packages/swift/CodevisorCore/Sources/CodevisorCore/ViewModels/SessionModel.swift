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
  public internal(set) var transcriptProjectionRevision: UInt64 = 0

  public static let initialTranscriptPageSize = 8
  static let olderTranscriptPageSize = 16
  static var cancellationTerminalEventWaitDelay: Duration = .milliseconds(100)
  public internal(set) var settledConversation: [ConversationItem] = [] {
    didSet { transcriptProjectionRevision &+= 1 }
  }
  public internal(set) var activeItem: ConversationItem? {
    didSet {
      activeItemRevision &+= 1
      let ticking = TranscriptActiveWorkedTicking(activeItem)
      if ticking != activeWorkedTicking { activeWorkedTicking = ticking }
      if activeItem?.id != oldValue?.id, hasActiveItem {
        transcriptProjectionRevision &+= 1
      }
    }
  }
  public private(set) var activeItemRevision: UInt64 = 0
  public private(set) var activeWorkedTicking: TranscriptActiveWorkedTicking?
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
  public internal(set) var presentsBotConversation = false {
    didSet {
      if presentsBotConversation != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var botMessages: [ServerBotMessage] = [] {
    didSet {
      if botMessages != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var outgoingMessages: [OutgoingMessage] = [] {
    didSet {
      if outgoingMessages != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var acceptedMessageIDs: Set<UUID> = [] {
    didSet {
      if acceptedMessageIDs != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var slowMessageIDs: Set<UUID> = [] {
    didSet {
      if slowMessageIDs != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var failedMessageIDs: Set<UUID> = [] {
    didSet {
      if failedMessageIDs != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var unreachedSend: UnreachedSend?
  var sendRetryDelays: [Duration] = [.seconds(1), .seconds(3)]
  var sendingNoticeDelay: Duration = .seconds(1)
  public internal(set) var hasOlderBotMessages = false
  public internal(set) var isLoadingOlderBotMessages = false
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
  let connectionRecovery: SessionConnectionRecovery
  let promptQueue: SessionPromptQueue
  let updateRoutes = SessionUpdateRoutes()
  let stalledTurnWatch: SessionStalledTurnWatch
  public var queuedPrompts: [ServerPromptQueueItem] { promptQueue.items }
  public internal(set) var updateGateHarnessName: String? {
    didSet {
      if updateGateHarnessName != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var autoResume: SessionAutoResume? {
    didSet {
      guard autoResume != oldValue else { return }
      activeItemRevision &+= 1
      transcriptProjectionRevision &+= 1
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
  @ObservationIgnored var settledIndexById: [UUID: Int] = [:]

  public var waitingBackgroundTasks: [BackgroundTaskInfo] {
    backgroundTasks.filter { $0.taskType == "subagent" }
  }

  public var isWaitingOnBackgroundTasks: Bool {
    !isSending && !waitingBackgroundTasks.isEmpty
  }

  public private(set) var runningSubagentToolCallIds: Set<String> = []

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
  public var onPromptNotSteered: ((UUID) -> Void)?

  @ObservationIgnored public var promptClientId: String?

  let transport: ServerSessionTransport
  private let sessionId: String
  let now: @Sendable () -> Date
  var serverEventCursor: Int?
  var isReplayingHistory = false
  var historicalConfigSelections: [String: String] = [:]

  var consumerTask: Task<Void, Never>?

  @ObservationIgnored nonisolated let pendingEvents = SessionEventBuffer()
  @ObservationIgnored var isFlushScheduled = false
  @ObservationIgnored var scheduledFlushTask: Task<Void, Never>?
  @ObservationIgnored var presentationFrameRequester: (@MainActor () -> Bool)?
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
    self.promptQueue = SessionPromptQueue(transport: serverTransport)
    self.sessionId = sessionId
    self.modeState = modeState
    self.configOptions = configOptions
    self.now = now
    self.stalledTurnWatch = SessionStalledTurnWatch(scheduler: quietTurnScheduler)
    self.connectionRecovery = SessionConnectionRecovery(
      scheduler: connectionRecoveryScheduler,
      statusDelay: connectionRecoveryStatusDelay,
      retryBaseDelay: connectionRecoveryRetryBaseDelay,
      retryMaximumDelay: connectionRecoveryRetryMaximumDelay
    )
    self.streamReconnectNotice = DelayedConnectionNotice(
      delay: connectionRecoveryStatusDelay, now: connectionRecoveryScheduler.now,
      sleep: connectionRecoveryScheduler.sleep)
    connectionRecovery.model = self
    streamReconnectNotice.onVisibilityChange = { [weak self] isVisible in
      self?.connectionRecovery.streamReconnectNoticeChanged(isVisible: isVisible)
    }
    promptQueue.onMessageQueued = { [weak self] id in
      self?.confirmOutgoing(id)
    }
    promptQueue.onFailure = { [weak self] error in
      self?.errorMessage = serverErrorMessage(error)
    }
  }

  @ObservationIgnored var appliedUpdateCount = 0

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
