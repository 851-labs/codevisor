import ACPKit
import Foundation
import TranscriptKit

struct ServerTranscriptResolver: Sendable {
  let transport: ServerSessionTransport

  func completeHistoryPage(
    _ page: TranscriptHistoryPage, before: String?, limit: Int
  ) async throws -> TranscriptHistoryPage {
    var page = page
    var changed: ToolDetailResource?
    while true {
      do { return try await resolve(page) } catch let ServerTranscriptContent.LoadError.changed(resource) {
        changed = try Self.retrying(after: resource, previous: changed)
        try Task.checkCancellation()
        page = try await transport.transcriptPage(before: before, limit: limit)
      }
    }
  }

  func transcriptDetailEvents(
    itemId: String
  ) async throws -> (details: ServerTranscriptItemDetails, events: [ServerSessionStreamEvent]) {
    let details = try await transcriptDetails(itemId: itemId)
    try Task.checkCancellation()
    return (details, ServerTranscriptHistoryMapper.detailEvents(from: details, sessionId: transport.sessionId))
  }

  func transcriptDetails(itemId: String) async throws -> ServerTranscriptItemDetails {
    var changed: ToolDetailResource?
    while true {
      do { return try await completeDetails(itemId: itemId) } catch let ServerTranscriptContent.LoadError
        .changed(resource)
      {
        changed = try Self.retrying(after: resource, previous: changed)
        try Task.checkCancellation()
      }
    }
  }

  private static func retrying(
    after resource: ToolDetailResource, previous: ToolDetailResource?
  ) throws -> ToolDetailResource {
    guard previous != resource else { throw ServerTranscriptContent.LoadError.changed(resource) }
    return resource
  }

  private func resolve(_ page: TranscriptHistoryPage) async throws -> TranscriptHistoryPage {
    let content = ServerTranscriptContent(transport: transport)
    var page = page
    for index in page.conversation.indices {
      page.conversation[index] = try await resolve(page.conversation[index], content: content)
    }
    return page
  }

  private func resolve(_ item: ConversationItem, content: ServerTranscriptContent) async throws -> ConversationItem {
    switch item {
    case let .user(message):
      return .user(try await resolveText(of: message, content: content))
    case var .assistant(message):
      try await resolveTurn(&message.turn, content: content)
      return .assistant(message)
    }
  }

  private func resolveText(of message: UserMessage, content: ServerTranscriptContent) async throws -> UserMessage {
    guard let resource = message.textResource, let field = Self.textField(of: resource) else { return message }

    var message = message
    message.text = try await content.field(field, resource: resource)
    message.textResource = nil
    return message
  }

  private func resolveTurn(_ turn: inout AssistantTurn, content: ServerTranscriptContent) async throws {
    for entryIndex in turn.entries.indices {
      try await resolveTextEntry(at: entryIndex, of: &turn, content: content)
    }
    try await resolvePlan(of: &turn, content: content)
  }

  private func resolveTextEntry(
    at index: Int, of turn: inout AssistantTurn, content: ServerTranscriptContent
  ) async throws {
    guard case let .text(id, _) = turn.entries[index],
      let resource = turn.textStates[":\(id)"]?.resource,
      let field = Self.textField(of: resource)
    else { return }

    let text = try await content.field(field, resource: resource)
    turn.entries[index] = .text(id: id, markdown: text)
    turn.textStates[":\(id)"]?.resource = nil
  }

  private func resolvePlan(of turn: inout AssistantTurn, content: ServerTranscriptContent) async throws {
    guard let resource = turn.planResource, let field = resource.fields.first else { return }

    turn.planDocument = try await content.field(field, resource: resource)
    turn.planResource = nil
  }

  private static func textField(of resource: ToolDetailResource) -> ToolDetailResource.Field? {
    resource.fields.first(where: { $0.name == "text" })
  }

  private func completeDetails(itemId: String) async throws -> ServerTranscriptItemDetails {
    let content = ServerTranscriptContent(transport: transport)
    var merge = ServerTranscriptDetailsMerge(itemId: itemId)
    var cursor: String?
    repeat {
      try Task.checkCancellation()
      let page = try await transport.client.transcriptItemDetails(
        id: transport.sessionId, itemId: itemId, after: cursor)
      merge.recordVersions(of: page)
      for entry in page.entries where merge.needs(entry) {
        let completed = try await Self.completed(entry, content: content)
        merge.add(completed)
      }
      cursor = try merge.advance(to: page.nextAfter)
    } while cursor != nil
    return merge.details
  }

  private static func completed(
    _ entry: ServerTranscriptEntry, content: ServerTranscriptContent
  ) async throws -> ServerTranscriptEntry {
    var entry = entry
    entry.payload = try await content.payload(entry.payload)
    return entry
  }
}
