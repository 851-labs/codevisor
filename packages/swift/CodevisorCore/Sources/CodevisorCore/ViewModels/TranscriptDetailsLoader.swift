import Foundation
import ACPKit

@MainActor
final class TranscriptDetailsLoader {
  private struct CachedDetails {
    let revision: Int
    let turn: AssistantTurn
  }

  private enum Storage {
    case settled(Int)
    case active
  }

  private struct Location {
    let storage: Storage
    let item: ConversationItem
  }

  weak var model: SessionModel?
  private let transport: ServerSessionTransport
  private var cache: [String: CachedDetails] = [:]
  private var loadTasks: [String: Task<Bool, Never>] = [:]

  init(transport: ServerSessionTransport) {
    self.transport = transport
  }

  func restoreActive(in conversation: [ConversationItem]) {
    for item in conversation {
      guard case let .assistant(message) = item, message.turn.isGenerating else { continue }
      loadDeferred(of: message)
    }
  }

  func loadDeferred(of message: AssistantMessage) {
    guard !message.turn.hasHydratedWorkedDetails, let itemID = message.turn.deferredDetailItemId else { return }
    _ = startLoad(itemId: itemID)
  }

  @discardableResult
  func load(itemId: String) async -> Bool {
    if restoreIfCached(itemId: itemId) { return true }
    return await startLoad(itemId: itemId).value
  }

  func cancelAll() {
    for task in loadTasks.values { task.cancel() }
    loadTasks.removeAll(keepingCapacity: false)
  }

  func restoringCachedDetails(_ item: ConversationItem) -> ConversationItem {
    guard case let .assistant(message) = item,
      let itemId = message.turn.deferredDetailItemId,
      let cached = cache[itemId],
      cached.revision == message.turn.detailRevision
    else { return item }
    return .assistant(AssistantMessage(id: message.id, turn: cached.turn))
  }

  nonisolated static func hydratedTurn(_ original: AssistantTurn, events: [ServerSessionStreamEvent]) -> AssistantTurn {
    var turn = original
    for event in events { apply(event, to: &turn) }
    keepLiveState(of: original, in: &turn)
    markHydrated(&turn, detailRevision: original.detailRevision)
    return turn
  }

  private func startLoad(itemId: String) -> Task<Bool, Never> {
    if let task = loadTasks[itemId] { return task }
    let task = Task { @MainActor [weak self] in
      guard let self, let model = self.model else { return false }
      defer { self.loadTasks.removeValue(forKey: itemId) }
      return await self.fetch(itemId: itemId, into: model)
    }
    loadTasks[itemId] = task
    return task
  }

  private func fetch(itemId: String, into model: SessionModel) async -> Bool {
    do {
      let (details, events) = try await transport.transcriptDetailEvents(itemId: itemId)
      try Task.checkCancellation()
      return hydrate(itemId, with: events, revision: details.revision, in: model)
    } catch {
      if !isTaskCancellation(error) { model.errorMessage = serverErrorMessage(error) }
      return false
    }
  }

  private func hydrate(
    _ itemId: String, with events: [ServerSessionStreamEvent], revision: Int, in model: SessionModel
  ) -> Bool {
    guard let location = location(of: itemId, in: model), case let .assistant(original) = location.item
    else { return false }

    var turn = Self.hydratedTurn(original.turn, events: events)
    turn.detailRevision = max(turn.detailRevision, revision)
    if !turn.isGenerating { cache[itemId] = CachedDetails(revision: revision, turn: turn) }
    install(.assistant(AssistantMessage(id: original.id, turn: turn)), at: location.storage, in: model)
    return true
  }

  private func restoreIfCached(itemId: String) -> Bool {
    guard let cached = cache[itemId] else { return false }
    guard let model, let location = location(of: itemId, in: model) else { return true }
    guard case let .assistant(original) = location.item, cached.revision == original.turn.detailRevision
    else { return false }

    install(.assistant(AssistantMessage(id: original.id, turn: cached.turn)), at: location.storage, in: model)
    return true
  }

  private func install(_ item: ConversationItem, at storage: Storage, in model: SessionModel) {
    let item = model.carryingLiveTurnState(item)
    switch storage {
    case let .settled(index): model.settledConversation[index] = item
    case .active: model.activeItem = item
    }
    guard case let .assistant(message) = item else { return }
    model.updateRoutes.recordToolCalls(of: message)
  }

  private func location(of itemId: String, in model: SessionModel) -> Location? {
    if let index = model.settledConversation.firstIndex(where: { Self.defers($0, to: itemId) }) {
      return Location(storage: .settled(index), item: model.settledConversation[index])
    }
    if let activeItem = model.activeItem, Self.defers(activeItem, to: itemId) {
      return Location(storage: .active, item: activeItem)
    }
    return nil
  }

  private nonisolated static func defers(_ item: ConversationItem, to itemId: String) -> Bool {
    guard case let .assistant(message) = item else { return false }
    return message.turn.deferredDetailItemId == itemId
  }

  private nonisolated static func apply(_ event: ServerSessionStreamEvent, to turn: inout AssistantTurn) {
    switch event {
    case let .update(update):
      TranscriptReducer.apply(update, to: &turn)
    case let .assistantFinalized(markdown, messageId, attachments):
      TranscriptReducer.finalizeAssistant(markdown: markdown, messageId: messageId, attachments: attachments, to: &turn)
    case let .finished(reason, detail, stopKind, retryable, _):
      turn.stopReason = reason
      turn.stopDetail = detail
      turn.stopKind = stopKind
      turn.retryable = retryable
      turn.isGenerating = false
    case let .failed(message, retryable, _):
      turn.stopDetail = message
      turn.retryable = retryable
      turn.isGenerating = false
    case let .authenticationRequired(message):
      turn.stopDetail = message
      turn.isGenerating = false
    case .assistantItemStarted, .synchronization, .userMessage, .queueUpdated, .retrying, .backgroundTasks,
      .runtimeState, .planApprovalRequired, .updateGate, .autoResume, .modelFallback, .botMessage:
      break
    }
  }

  private nonisolated static func keepLiveState(of original: AssistantTurn, in turn: inout AssistantTurn) {
    turn.isGenerating = original.isGenerating
    turn.startedAt = original.startedAt
    turn.endedAt = original.endedAt
    turn.planProposedAt = original.planProposedAt
    turn.planResumedAt = original.planResumedAt
    turn.stopReason = original.stopReason
    turn.stopDetail = original.stopDetail
    turn.stopKind = original.stopKind
    turn.retryable = original.retryable
    turn.planDocument = turn.planDocument ?? original.planDocument
    if turn.attachments.isEmpty { turn.attachments = original.attachments }
  }

  private nonisolated static func markHydrated(_ turn: inout AssistantTurn, detailRevision: Int) {
    turn.deferredDetailItemId = nil
    turn.hasDeferredWorkedDetails = false
    turn.detailRevision = detailRevision
    turn.hasHydratedWorkedDetails = true
  }
}
