import Foundation
import ACPKit

@MainActor
struct SessionHistoryFetch {
  private struct DeferredDetails {
    let message: AssistantMessage
    let itemID: String
  }

  let transport: ServerSessionTransport

  func firstPage(preloaded: TranscriptHistoryPage?) async throws -> TranscriptHistoryPage {
    if let preloaded { return preloaded }
    return try await transport.transcriptPage(limit: SessionModel.initialTranscriptPageSize)
  }

  func completePage(_ page: TranscriptHistoryPage) async throws -> TranscriptHistoryPage {
    try await transport.completeHistoryPage(page, limit: SessionModel.initialTranscriptPageSize)
  }

  func hydratingDetails(
    of page: TranscriptHistoryPage, shownIn conversation: [ConversationItem]
  ) async throws -> TranscriptHistoryPage {
    var page = page
    let hydratedIDs = Self.hydratedAssistantIDs(in: conversation)
    for index in page.conversation.indices {
      guard let details = Self.deferredDetails(of: page.conversation[index], hydratedIDs: hydratedIDs)
      else { continue }
      page.conversation[index] = try await hydrated(details)
    }
    return page
  }

  private func hydrated(_ details: DeferredDetails) async throws -> ConversationItem {
    let (_, events) = try await transport.transcriptDetailEvents(itemId: details.itemID)
    let turn = SessionModel.hydratedTranscriptTurn(details.message, events: events)
    return .assistant(AssistantMessage(id: details.message.id, turn: turn))
  }

  private nonisolated static func hydratedAssistantIDs(in conversation: [ConversationItem]) -> Set<UUID> {
    Set(
      conversation.compactMap { item -> UUID? in
        guard case let .assistant(message) = item, message.turn.hasHydratedWorkedDetails else { return nil }
        return message.id
      })
  }

  private nonisolated static func deferredDetails(
    of item: ConversationItem, hydratedIDs: Set<UUID>
  ) -> DeferredDetails? {
    guard case let .assistant(message) = item,
      let itemID = message.turn.deferredDetailItemId,
      needsFreshDetails(message, hydratedIDs: hydratedIDs)
    else { return nil }
    return DeferredDetails(message: message, itemID: itemID)
  }

  private nonisolated static func needsFreshDetails(_ message: AssistantMessage, hydratedIDs: Set<UUID>) -> Bool {
    message.turn.isGenerating || hydratedIDs.contains(message.id)
  }
}
