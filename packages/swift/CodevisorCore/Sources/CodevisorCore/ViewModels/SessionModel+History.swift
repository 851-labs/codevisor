import Foundation
import ACPKit

enum SessionHistoryLoadOutcome {
  case loaded
  case cancelled
  case failed(message: String, retryable: Bool)
}

extension SessionModel {
  public func transcriptBodyPage(
    resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    try await transport.transcriptBodyPage(resource: resource, field: field, position: position)
  }

  func loadHistoryForInitialDisplay(preloaded: TranscriptHistoryPage? = nil) async {
    surfaceHistoryLoadFailure(
      await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: true)
    )
  }

  func loadHistoryReplacingCachedDisplay(preloaded: TranscriptHistoryPage?) async {
    surfaceHistoryLoadFailure(
      await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: true, preservingContent: true)
    )
  }

  func loadHistoryForConnectionRecovery() async -> SessionHistoryLoadOutcome {
    await loadHistoryOnce(preloaded: nil, defersPromptQueue: false, preservingContent: true)
  }

  func appliedStateIsCurrent(through cursor: Int) -> Bool {
    guard let applied = serverEventCursor,
      applied < ServerSessionTransport.liveOnlyEventCursor,
      hasActiveItem || !settledConversation.isEmpty
    else { return false }
    return applied > cursor
  }

  private func surfaceHistoryLoadFailure(_ outcome: SessionHistoryLoadOutcome) {
    guard case let .failed(message, _) = outcome else { return }
    errorMessage = message
  }

  @discardableResult
  public func loadOlderHistory() async -> Int {
    guard historyPaging.canLoadOlderPage else { return 0 }
    historyPaging.isLoadingOlderPage = true
    defer { historyPaging.isLoadingOlderPage = false }
    do {
      while historyPaging.hasOlderPages, let cursor = historyPaging.olderPageCursor {
        let anchor = conversation.first?.id
        let page = try await transport.completeHistoryPage(
          transport.transcriptPage(before: cursor, limit: Self.olderTranscriptPageSize),
          before: cursor, limit: Self.olderTranscriptPageSize)
        try Task.checkCancellation()
        guard historyPaging.olderPageCursor == cursor, conversation.first?.id == anchor else { continue }
        let existing = Set(conversation.map(\.id))
        let unique = page.conversation
          .map(transcriptDetails.restoringCachedDetails)
          .filter {
            $0.hasRenderableTranscriptContent && !existing.contains($0.id)
          }
        settledConversation.insert(contentsOf: unique, at: 0)
        rebuildSettledIndex()
        historyPaging.adopt(page)
        return unique.count
      }
      return 0
    } catch {
      if !isTaskCancellation(error) {
        errorMessage = serverErrorMessage(error)
      }
      return 0
    }
  }
}
