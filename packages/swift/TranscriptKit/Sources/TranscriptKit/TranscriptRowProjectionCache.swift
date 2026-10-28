import CoreGraphics
import CodevisorProtocol
import Foundation

public struct TranscriptProjectionKey: Hashable, Sendable {
  public let sessionID: UUID
  public let controllerRevision: UInt64
  public let modelRevision: UInt64
  public let activityMessage: String?

  public init(sessionID: UUID, controllerRevision: UInt64, modelRevision: UInt64, activityMessage: String? = nil) {
    self.sessionID = sessionID
    self.controllerRevision = controllerRevision
    self.modelRevision = modelRevision
    self.activityMessage = activityMessage
  }
}

public struct TranscriptProjectionOptions: Hashable, Sendable {
  public let includesConnectingRow: Bool
  public let bottomSpacerHeight: CGFloat?
  public let presentsBotConversation: Bool

  public init(
    includesConnectingRow: Bool,
    bottomSpacerHeight: CGFloat? = nil,
    presentsBotConversation: Bool = false
  ) {
    self.includesConnectingRow = includesConnectingRow
    self.bottomSpacerHeight = bottomSpacerHeight
    self.presentsBotConversation = presentsBotConversation
  }
}

public struct TranscriptProjectionRequest: Hashable, Sendable {
  public let key: TranscriptProjectionKey
  public let options: TranscriptProjectionOptions

  public init(key: TranscriptProjectionKey, options: TranscriptProjectionOptions) {
    self.key = key
    self.options = options
  }
}

public struct TranscriptPresentationRow: Identifiable, Equatable, Sendable {
  static func interaction(
    _ interaction: TranscriptInteraction,
    inBotConversation: Bool,
    spacingAfter: CGFloat? = nil
  ) -> TranscriptPresentationRow {
    .init(
      id: .interaction(interaction.id),
      content: .interaction(interaction, inBotConversation: inBotConversation),
      estimatedHeight: interaction.isPending ? 240 : 44,
      measurementRevision: interaction.isPending ? 0 : 1,
      spacingAfter: spacingAfter
    )
  }

  static func setupRequest(
    _ request: TranscriptSetupRequest,
    inBotConversation: Bool,
    spacingAfter: CGFloat? = nil
  ) -> TranscriptPresentationRow {
    let revision =
      switch request.state {
      case .pending: 0
      case .setUp: 1
      case .declined: 2
      }
    return .init(
      id: .setupRequest(request.id),
      content: .setupRequest(request, inBotConversation: inBotConversation),
      estimatedHeight: 60,
      measurementRevision: revision,
      spacingAfter: spacingAfter
    )
  }

  public enum ID: Hashable, Sendable {
    case message(UUID)
    case assistantPlanning(UUID)
    case activePlanning(UUID)
    case plan(UUID)
    case planHeader(UUID)
    case activePlanHeader(UUID)
    case planMarkdown(UUID, ordinal: Int, fragment: String?)
    case activePlanMarkdown(UUID, ordinal: Int, fragment: String?)
    case assistantResult(UUID)
    case activeResult(UUID)
    case assistantWorkedHeader(UUID, TranscriptWorkedSectionKind)
    case activeWorkedHeader(UUID, TranscriptWorkedSectionKind)
    case assistantWorkedItem(UUID, TranscriptWorkedSectionKind, itemID: String)
    case activeWorkedItem(UUID, TranscriptWorkedSectionKind, itemID: String)
    case assistantChrome(UUID, TranscriptAssistantChromeSlice)
    case activeChrome(UUID, TranscriptAssistantChromeSlice)
    case assistantMarkdown(UUID, sourceID: String, ordinal: Int, fragment: String?)
    case activeMarkdown(UUID, sourceID: String, ordinal: Int, fragment: String?)
    case assistantAttachment(UUID, sourceID: String, ordinal: Int)
    case activeAttachment(UUID, sourceID: String, ordinal: Int)
    case assistantPluginApps(UUID)
    case activePluginApps(UUID)
    case active(UUID)
    case botMessage(String)
    case botTimestamp(String)
    case delivery(UUID)
    case botTyping
    case setupRequest(String)
    case interaction(String)
    case setup
    case startingAgent
    case backgroundTask
    case updateGate
    case connecting
    case serverWait
    case error
    case statusError
    case bottomSpacer

    public var layoutKey: String {
      switch self {
      case let .message(id): "message:\(id.uuidString)"
      case let .assistantPlanning(id), let .activePlanning(id):
        "message:\(id.uuidString):planning"
      case let .plan(id): "message:\(id.uuidString):plan"
      case let .planHeader(id), let .activePlanHeader(id):
        "message:\(id.uuidString):plan:header"
      case let .planMarkdown(id, ordinal, fragment),
        let .activePlanMarkdown(id, ordinal, fragment):
        "message:\(id.uuidString):plan:markdown:\(ordinal)\(fragmentComponent(fragment))"
      case let .assistantResult(id), let .activeResult(id):
        "message:\(id.uuidString):result"
      case let .assistantWorkedHeader(id, section),
        let .activeWorkedHeader(id, section):
        "message:\(id.uuidString):worked:\(section.layoutComponent):header"
      case let .assistantWorkedItem(id, section, itemID),
        let .activeWorkedItem(id, section, itemID):
        "message:\(id.uuidString):worked:\(section.layoutComponent):item:\(itemID)"
      case let .assistantChrome(id, slice), let .activeChrome(id, slice):
        "message:\(id.uuidString):chrome:\(slice.layoutComponent)"
      case let .assistantMarkdown(id, sourceID, ordinal, fragment),
        let .activeMarkdown(id, sourceID, ordinal, fragment):
        "message:\(id.uuidString):markdown:\(sourceID):\(ordinal)\(fragmentComponent(fragment))"
      case let .assistantAttachment(id, sourceID, ordinal),
        let .activeAttachment(id, sourceID, ordinal):
        "message:\(id.uuidString):attachment:\(sourceID):\(ordinal)"
      case let .assistantPluginApps(id), let .activePluginApps(id):
        "message:\(id.uuidString):apps"
      case let .active(id): "message:\(id.uuidString)"
      case let .botMessage(id): "bot:\(id)"
      case let .botTimestamp(id): "bot:\(id):timestamp"
      case let .delivery(id): "message:\(id.uuidString):delivery"
      case .botTyping: "special:bot-typing"
      case let .setupRequest(id): "setup-request:\(id)"
      case let .interaction(id): "interaction:\(id)"
      case .setup: "special:setup"
      case .startingAgent: "special:starting-agent"
      case .backgroundTask: "special:background"
      case .updateGate: "special:update-gate"
      case .connecting: "special:connecting"
      case .serverWait: "special:server-wait"
      case .error: "special:error"
      case .statusError: "special:status-error"
      case .bottomSpacer: "special:bottom-spacer"
      }
    }

    private func fragmentComponent(_ fragment: String?) -> String {
      fragment.map { ":fragment:\($0)" } ?? ""
    }

    public var isCacheableSettledRow: Bool {
      switch self {
      case .message, .assistantPlanning, .plan, .planHeader, .planMarkdown,
        .assistantResult, .assistantWorkedHeader, .assistantWorkedItem,
        .assistantChrome, .assistantMarkdown, .assistantAttachment, .assistantPluginApps, .botMessage,
        .botTimestamp:
        true
      case .delivery, .botTyping, .active, .activePlanning, .activePlanHeader, .activePlanMarkdown,
        .activeResult, .activeWorkedHeader, .activeWorkedItem, .activeChrome,
        .activeMarkdown, .activeAttachment, .activePluginApps, .setupRequest, .interaction, .setup, .startingAgent,
        .backgroundTask, .updateGate, .connecting, .serverWait, .error,
        .statusError, .bottomSpacer:
        false
      }
    }

    public var isActiveRow: Bool {
      switch self {
      case .active, .activePlanning, .activePlanHeader, .activePlanMarkdown,
        .activeResult, .activeWorkedHeader, .activeWorkedItem, .activeChrome,
        .activeMarkdown, .activeAttachment, .activePluginApps:
        true
      default: false
      }
    }

    public var messageID: UUID? {
      switch self {
      case let .message(id), let .assistantPlanning(id), let .activePlanning(id),
        let .plan(id), let .planHeader(id), let .activePlanHeader(id),
        let .planMarkdown(id, _, _), let .activePlanMarkdown(id, _, _),
        let .assistantResult(id), let .activeResult(id), let .active(id):
        id
      case let .assistantWorkedHeader(id, _), let .activeWorkedHeader(id, _),
        let .assistantWorkedItem(id, _, _), let .activeWorkedItem(id, _, _):
        id
      case let .assistantChrome(id, _), let .activeChrome(id, _),
        let .assistantMarkdown(id, _, _, _), let .activeMarkdown(id, _, _, _),
        let .assistantAttachment(id, _, _), let .activeAttachment(id, _, _),
        let .assistantPluginApps(id), let .activePluginApps(id):
        id
      case .botMessage, .botTimestamp, .delivery, .botTyping, .setupRequest, .interaction, .setup, .startingAgent,
        .backgroundTask,
        .updateGate, .connecting, .serverWait, .error, .statusError, .bottomSpacer:
        nil
      }
    }
  }

  public enum Content: Equatable, Sendable {
    case message(ConversationItem, waitingOnBackgroundTask: String?)
    case assistantPlanning(AssistantMessage)
    case planDocument(String)
    case planHeader(lifecycle: TranscriptBlockLifecycle)
    case assistantResult(AssistantMessage, waitingOnBackgroundTask: String?)
    case assistantWorkedHeader(TranscriptWorkedSectionHeader)
    case activeWorkedHeader(TranscriptActiveWorkedSectionHeader)
    case assistantWorkedItem(TranscriptSettledWorkedItem)
    case activeWorkedItem(TranscriptWorkedItemReference)
    case assistantChrome(
      AssistantMessage,
      slice: TranscriptAssistantChromeSlice,
      waitingOnBackgroundTask: String?
    )
    case markdownChunk(TranscriptMarkdownChunk)
    case assistantAttachment(TranscriptAssistantAttachment)
    case pluginApps([CodevisorExecutionApp])
    case active(ConversationItem)
    case botMessage(TranscriptBotMessage, TranscriptBotMessageContent, isGroupTail: Bool)
    case botTimestamp(Date)
    case delivery(UUID, TranscriptDelivery, inBotConversation: Bool)
    case botTyping
    case setupRequest(TranscriptSetupRequest, inBotConversation: Bool)
    case interaction(TranscriptInteraction, inBotConversation: Bool)
    case setup([SessionSetupPhase])
    case optimistic(UserMessage)
    case startingAgent
    case backgroundTask(String)
    case updateGate(String)
    case connecting(String)
    case serverWait(String)
    case error(String)
    case bottomSpacer(CGFloat)
  }

  public let id: ID
  public let content: Content
  public let estimatedHeight: CGFloat
  public let measurementRevision: Int
  public let layoutKey: String
  public let spacingAfter: CGFloat?
  public let workedSection: TranscriptWorkedSectionMembership?
  public let finishedResponseItemId: UUID?

  public var isUserMessage: Bool {
    switch content {
    case let .message(item, waitingOnBackgroundTask: _):
      if case .user = item { return true }
      return false
    case .optimistic:
      return true
    default:
      return false
    }
  }

  public init(
    id: ID,
    content: Content,
    estimatedHeight: CGFloat,
    measurementRevision: Int = 0,
    spacingAfter: CGFloat? = nil,
    workedSection: TranscriptWorkedSectionMembership? = nil,
    finishedResponseItemId: UUID? = nil
  ) {
    self.id = id
    self.content = content
    self.estimatedHeight = estimatedHeight
    self.measurementRevision = measurementRevision
    self.spacingAfter = spacingAfter
    self.workedSection = workedSection
    layoutKey = id.layoutKey
    if let finishedResponseItemId {
      self.finishedResponseItemId = finishedResponseItemId
    } else {
      self.finishedResponseItemId =
        switch content {
        case let .message(item, waitingOnBackgroundTask: _):
          if case let .assistant(message) = item { message.id } else { nil }
        case let .assistantResult(message, waitingOnBackgroundTask: _):
          message.id
        case let .assistantChrome(message, slice, waitingOnBackgroundTask: _):
          slice == .epilogue && !message.turn.isGenerating ? message.id : nil
        case .assistantWorkedHeader, .activeWorkedHeader, .assistantWorkedItem,
          .activeWorkedItem, .planHeader, .markdownChunk, .assistantAttachment, .pluginApps:
          nil
        case let .active(item):
          if case let .assistant(message) = item, !message.turn.isGenerating {
            message.id
          } else {
            nil
          }
        default:
          nil
        }
    }
  }
}

public actor TranscriptRowProjectionCache {
  public static let shared = TranscriptRowProjectionCache()

  private struct CacheKey: Hashable {
    public let projection: TranscriptProjectionKey
    public let options: TranscriptProjectionOptions
  }

  private let capacity: Int
  private var rowsByKey: [CacheKey: [TranscriptPresentationRow]] = [:]
  private var recency: [CacheKey] = []

  public init(capacity: Int = 24) {
    self.capacity = max(1, capacity)
  }

  public func rows(
    for key: TranscriptProjectionKey,
    input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions
  ) throws -> [TranscriptPresentationRow] {
    let cacheKey = CacheKey(projection: key, options: options)
    if let cached = rowsByKey[cacheKey] {
      touch(cacheKey)
      return cached
    }

    let projected = try Self.project(input, options: options)
    guard !Task.isCancelled else { throw CancellationError() }
    rowsByKey[cacheKey] = projected
    touch(cacheKey)
    while recency.count > capacity {
      rowsByKey.removeValue(forKey: recency.removeFirst())
    }
    return projected
  }

  private func touch(_ key: CacheKey) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }

  public static func project(
    _ input: TranscriptProjectionInput,
    options: TranscriptProjectionOptions
  ) throws -> [TranscriptPresentationRow] {
    try TranscriptRowAssembly.assemble(input, options: options)
  }

  static func showsOptimisticAgentActivity(_ input: TranscriptProjectionInput) -> Bool {
    guard input.activityMessage == nil, input.sessionErrorMessage == nil else { return false }
    if case .failed = input.status { return false }
    return input.setupPhases.allSatisfy(\.isSucceeded)
  }
}
