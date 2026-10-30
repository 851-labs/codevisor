import Foundation
import ACPKit

extension SessionController {
  public var conversation: [ConversationItem] { model?.conversation ?? [] }
  public var settledConversation: [ConversationItem] {
    let settled = model?.settledConversation ?? []
    guard model?.activeItem == nil else { return settled }
    return TranscriptAutoResumeStamp.stamping(model?.autoResume, onto: settled)
  }
  public var activeItem: ConversationItem? {
    TranscriptAutoResumeStamp.stamping(model?.autoResume, onto: model?.activeItem)
  }
  public var activeItemRevision: UInt64 { model?.activeItemRevision ?? 0 }
  public var activeWorkedTicking: TranscriptActiveWorkedTicking? { model?.activeWorkedTicking }
  public var hasActiveItem: Bool { model?.hasActiveItem ?? false }
  public var transcriptProjectionKey: TranscriptProjectionKey {
    TranscriptProjectionKey(
      sessionID: transcriptProjectionID,
      controllerRevision: transcriptProjectionRevision,
      modelRevision: model?.transcriptProjectionRevision ?? 0,
      activityMessage: transcriptSandboxPower == nil ? transcriptActivityOverride : nil,
      sandboxPower: transcriptSandboxPower
    )
  }

  public var transcriptProjectionInput: TranscriptProjectionInput {
    let sandboxPower = transcriptSandboxPower
    let outgoing = transcriptOutgoing
    return TranscriptProjectionInput(
      settledConversation: settledConversation,
      pendingUserMessage: outgoing.opening,
      activeItem: activeItem,
      setupPhases: SessionSetupPhases.merging(live: setupPhases, persisted: model?.persistedSetupPhases ?? []),
      waitingBackgroundTaskDescription: waitingBackgroundTaskDescription,
      waitingHarnessUpdateName: waitingHarnessUpdateName,
      isLoadingInitialHistory: isAwaitingInitialHistory,
      serverWaitMessage: sandboxPower == nil ? serverWaitMessage : nil,
      sessionErrorMessage: sandboxPower == nil ? sessionErrorMessage : nil,
      status: sandboxPower == nil ? projectionStatus : .idle,
      activityMessage: sandboxPower == nil ? transcriptActivityOverride : nil,
      botConversation: presentedBotConversation,
      outgoingMessages: outgoing.messages,
      deliveries: outgoing.deliveries,
      sandboxPower: sandboxPower
    )
  }

  private var projectionStatus: TranscriptProjectionInput.ConnectionStatus {
    switch status {
    case .idle: .idle
    case let .connecting(message): .connecting(message)
    case let .failed(message): .failed(message)
    }
  }

  public var pendingUserMessage: UserMessage? {
    let outgoing = transcriptOutgoing
    guard let opening = outgoing.opening, outgoing.deliveries[opening.id]?.isFailed != true else { return nil }
    return opening
  }

  private var transcriptOutgoing: TranscriptOutgoing {
    let queued = unsentAgentSends
    var messages = (model?.transcriptOutgoingMessages ?? []) + queued.map(\.message)
    var deliveries = model?.transcriptDeliveries ?? [:]
    for entry in sends.unsent where !entry.route.landsInPromptQueue {
      guard case .agent = entry.route, deliveries[entry.message.id] == nil else { continue }
      deliveries[entry.message.id] = entry.delivery
    }
    let opensChat = model.map { $0.settledConversation.isEmpty && $0.activeItem == nil } ?? true
    let opening = opensChat && !messages.isEmpty ? messages.removeFirst() : nil
    return TranscriptOutgoing(opening: opening, messages: messages, deliveries: deliveries)
  }

  private var presentedBotConversation: TranscriptBotConversation? {
    let unsent = sends.unsentBotMessages
    if let conversation = model?.transcriptBotConversation(adding: unsent) { return conversation }
    guard presentsBotConversation else { return nil }
    return TranscriptBotConversation(messages: unsent.map(\.message), isWorking: false)
  }

  public var hasOlderBotMessages: Bool { model?.hasOlderBotMessages ?? false }
  public var isLoadingOlderBotMessages: Bool { model?.isLoadingOlderBotMessages ?? false }

  @discardableResult
  public func loadOlderBotMessages() async -> Int {
    await model?.loadOlderBotMessages() ?? 0
  }

  public var composerPlaceholder: String {
    presentsBotConversation ? "Message" : "Do something"
  }

  public func hasOlderHistory(presentingBotConversation: Bool) -> Bool {
    presentingBotConversation ? hasOlderBotMessages : hasOlderHistory
  }

  public func isLoadingOlderHistory(presentingBotConversation: Bool) -> Bool {
    presentingBotConversation ? isLoadingOlderBotMessages : isLoadingOlderHistory
  }

  @discardableResult
  public func loadOlderHistory(presentingBotConversation: Bool) async -> Int {
    if presentingBotConversation { return await loadOlderBotMessages() }
    return await loadOlderHistory()
  }
  public var hasOlderHistory: Bool { model?.hasOlderHistory ?? false }
  public var isLoadingOlderHistory: Bool { model?.isLoadingOlderHistory ?? false }
  public var queuedPrompts: [ServerPromptQueueItem] { model?.queuedPrompts.filter { !$0.isSystem } ?? [] }
  public var availableCommands: [AvailableCommand] { model?.availableCommands ?? [] }
  public var availableSkills: SessionSkills? { model?.availableSkills }
  public var isConnected: Bool { model != nil }
  public var canChooseHarness: Bool {
    settledConversation.isEmpty
      && !hasActiveItem
      && pendingUserMessage == nil
      && !isConnecting
      && serverSession?.hasAgentSession != true
      && resumeAgentSessionId?.isEmpty != false
  }

  public var modeState: SessionModeState? {
    if let live = model?.modeState { return live }
    guard let selectedHarnessId, var state = modeStateByHarness[selectedHarnessId] else { return nil }
    if let modeId = pendingConfiguration.modeId { state.currentModeId = modeId }
    return state
  }
  public var errorMessage: String? { model?.errorMessage }
  public var sessionErrorMessage: String? {
    guard let error = model?.errorMessage else { return nil }
    if case let .assistant(message)? = model?.activeItem,
      message.turn.stopDetail == error
    {
      return nil
    }
    return error
  }
  public var errorRequiresHarnessAuthentication: Bool {
    model?.errorRequiresHarnessAuthentication == true
  }

  @discardableResult
  public func loadOlderHistory() async -> Int {
    await model?.loadOlderHistory() ?? 0
  }

  @discardableResult
  public func loadTranscriptDetails(_ itemId: String) async -> Bool {
    await model?.transcriptDetails.load(itemId: itemId) ?? false
  }

  public func transcriptBodyPage(
    resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    guard let model else { throw SessionControllerError.serverUnavailable }
    return try await model.transcriptBodyPage(resource: resource, field: field, position: position)
  }

  public var activeHarnessId: String? { connectedHarnessId ?? selectedHarnessId }

  public var selectedHarness: ServerHarness? {
    harnesses.first { $0.id == selectedHarnessId }
  }

  public var activeHarnessName: String? {
    guard let activeHarnessId else { return nil }
    let reported = harnesses.first { $0.id == activeHarnessId }?.name
    return HarnessRegistry.displayName(for: activeHarnessId, reported: reported)
  }

  public var isConnecting: Bool {
    if case .connecting = status { return true }
    return false
  }

  public var isSending: Bool { model?.isSending ?? false }
  public var isCancelling: Bool { model?.isCancelling ?? false }
  public var canStop: Bool { isSending && !presentsBotConversation && !isAwaitingAnswer }
  public var isTakingLongerThanExpected: Bool {
    model?.isTakingLongerThanExpected ?? false
  }
  public var connectionRecoveryMessage: String? {
    if model != nil, machines?.showsReconnectNotice(for: project.serverId) == true {
      return "Reconnecting…"
    }
    return model?.connectionRecoveryMessage
  }

  public var hasVisibleTranscript: Bool { presentationClock.visibleViewCount > 0 }

  public var transcriptActivityOverride: String? {
    connectionRecoveryMessage ?? serverWaitMessage
      ?? waitingHarnessUpdateName.map { "Waiting for \($0) to finish updating..." }
  }

  public var modelFallbackMessage: String? {
    guard let fallback = model?.modelFallback else { return nil }
    let names =
      configOptions.first {
        $0.category == SessionConfigOption.Category.model || $0.id == "model"
      }?.options ?? []
    func name(_ value: String) -> String {
      names.first { $0.value == value }?.name ?? value
    }
    return "\(name(fallback.originalModel)) declined this request."
      + " Using \(name(fallback.fallbackModel)) for the rest of this chat."
  }

  public func dismissModelFallback() {
    model?.clearModelFallback()
  }

  public var isBusy: Bool {
    isConnecting || isSending
  }

  public var waitingBackgroundTasks: [BackgroundTaskInfo] { model?.waitingBackgroundTasks ?? [] }

  public var isWaitingOnBackgroundTasks: Bool { model?.isWaitingOnBackgroundTasks ?? false }

  public func canRetryTurn(_ id: UUID) -> Bool {
    guard !isSending,
      case let .assistant(message)? = conversation.last(where: {
        if case .assistant = $0 { return true }
        return false
      }),
      message.id == id,
      message.turn.retryable || message.turn.stopDetail != nil
    else { return false }
    return retryPrompt(before: id) != nil
  }

  public var waitingHarnessUpdateName: String? { model?.updateGateHarnessName }

  @discardableResult
  public func cancelAutoResume() async -> Bool { await model?.cancelAutoResume() ?? false }

  public var waitingBackgroundTaskDescription: String? {
    guard isWaitingOnBackgroundTasks else { return nil }
    let task = waitingBackgroundTasks.first
    let extra = waitingBackgroundTasks.count - 1
    return task.map {
      extra > 0 ? "\($0.description) and \(extra) more" : $0.description
    } ?? "background task"
  }

  public var waitingSubagentCalls: [ToolCall] { model?.waitingSubagentCalls ?? [] }

  public var runningSubagentToolCallIds: Set<String> { model?.runningSubagentToolCallIds ?? [] }

}

extension SessionController {
  public func presentBotConversation() {
    guard !presentsBotConversation else { return }
    presentsBotConversation = true
    model?.presentBotConversation()
  }

  public func retryUnsentMessage(id: UUID) async {
    if sends.holdsFailure(id) { return sends.retry(id) }
    await model?.retryUnsentMessage(id: id)
  }

  public func deleteUnsentMessage(id: UUID) {
    if sends.holdsFailure(id) { return sends.delete(id) }
    model?.deleteUnsentMessage(id: id)
  }
}

private struct TranscriptOutgoing {
  let opening: UserMessage?
  let messages: [UserMessage]
  let deliveries: [UUID: TranscriptDelivery]
}
