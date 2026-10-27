import Foundation
import ACPKit

@MainActor
final class SessionStalledTurnWatch {
  private static let quietInterval: Duration = .seconds(300)

  private let scheduler: SessionQuietTurnScheduler
  private var schedule: SessionQuietTurnCancellation?

  init(scheduler: SessionQuietTurnScheduler) {
    self.scheduler = scheduler
  }

  func restart(for model: SessionModel) {
    schedule?.cancel()
    schedule = scheduler.schedule(Self.quietInterval) { [weak model] in
      guard let model, model.isSending, model.pendingQuestion == nil else { return }
      await Self.reloadStalledTurn(model)
    }
  }

  func stop() {
    schedule?.cancel()
    schedule = nil
  }

  nonisolated static func isProviderActivity(_ event: ServerSessionStreamEvent) -> Bool {
    switch event {
    case let .update(update):
      isProviderUpdate(update)
    case .retrying, .userMessage, .assistantItemStarted, .assistantFinalized:
      true
    case .synchronization, .finished, .failed, .authenticationRequired, .queueUpdated, .updateGate,
      .autoResume, .backgroundTasks, .runtimeState, .planApprovalRequired, .modelFallback, .botMessage:
      false
    }
  }

  private static func reloadStalledTurn(_ model: SessionModel) async {
    model.isTakingLongerThanExpected = true
    let cursorBeforeReload = model.serverEventCursor
    await model.reconcileFromServer()
    guard model.isSending else { return }

    if !cursorAdvanced(from: cursorBeforeReload, to: model.serverEventCursor) {
      model.isTakingLongerThanExpected = true
    }
  }

  private nonisolated static func cursorAdvanced(from before: Int?, to after: Int?) -> Bool {
    guard let before, let after else { return false }
    return after > before
  }

  private nonisolated static func isProviderUpdate(_ update: SessionUpdate) -> Bool {
    switch update {
    case .agentMessagePatch, .agentMessageChunk, .agentThoughtChunk, .plan, .planDocument,
      .toolCall, .toolCallUpdate, .question, .questionResolved, .contextCompaction:
      true
    case .userMessageChunk, .availableCommandsUpdate, .availableSkillsUpdate, .currentModeUpdate,
      .configOptionUpdate, .usageUpdate, .goalUpdate, .goalCleared:
      false
    }
  }
}
