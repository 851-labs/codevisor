import ACPKit
import Foundation
import TranscriptKit

/// Storage paging ends here. Native transcript views receive complete values
/// and keep their original row identities, disclosure, and streaming behavior.
actor ServerTranscriptContent {
  enum LoadError: Error { case changed(ToolDetailResource) }

  private struct CachedField {
    let metadata: ToolDetailResource.Field
    let text: String
  }

  private let transport: ServerSessionTransport
  private var cache: [String: CachedField] = [:]

  init(transport: ServerSessionTransport) { self.transport = transport }

  func field(_ field: ToolDetailResource.Field, resource: ToolDetailResource) async throws -> String {
    let key = "\(resource.itemId):\(resource.entryKey):\(field.name)"
    if let cached = cache[key], cached.metadata == field { return cached.text }
    let expectedRevision = field.generation ?? field.revision
    let transport = self.transport
    var blocks: [ServerTranscriptBodyPage]
    if let count = field.pageCount {
      // Fetch a bounded number concurrently. A large document must not incur
      // one sequential network round trip for every 8K storage block.
      blocks = try await withThrowingTaskGroup(of: ServerTranscriptBodyPage.self) { group in
        var next = 0
        func enqueue(_ position: Int) {
          group.addTask {
            try Task.checkCancellation()
            return try await Self.block(transport: transport, resource: resource, field: field.name, position: position)
          }
        }
        while next < min(8, count) { enqueue(next); next += 1 }
        var result: [ServerTranscriptBodyPage] = []
        while let block = try await group.next() {
          guard block.revision == expectedRevision else { throw LoadError.changed(resource) }
          result.append(block)
          if next < count { enqueue(next); next += 1 }
        }
        return result.sorted { $0.position < $1.position }
      }
    } else {
      blocks = []
      var position = 0
      repeat {
        try Task.checkCancellation()
        let block = try await Self.block(
          transport: transport, resource: resource, field: field.name, position: position)
        guard block.revision == expectedRevision else { throw LoadError.changed(resource) }
        blocks.append(block)
        guard let next = block.nextPosition else { break }
        guard next > position else { throw CodevisorServerClientError.invalidResponse }
        position = next
      } while true
    }
    try Task.checkCancellation()
    var text = blocks.map(\.text).joined()
    if field.name == "text", field.generation != nil {
      // Appends may extend the last block while it is being fetched. Install
      // exactly this snapshot's prefix; the journal delivers the suffix.
      let length = field.sizeBytes / 2
      guard text.utf16.count >= length else { throw LoadError.changed(resource) }
      text = (text as NSString).substring(to: length)
    }
    cache[key] = CachedField(metadata: field, text: text)
    return text
  }

  private static func block(
    transport: ServerSessionTransport, resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    do {
      return try await transport.transcriptBodyPage(resource: resource, field: field, position: position)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      // A replacement can shorten the body or move a tool field back inline.
      // Reload its metadata; repeated failure of unchanged metadata is an error.
      throw LoadError.changed(resource)
    }
  }

  func payload(_ payload: JSONValue) async throws -> JSONValue {
    guard case var .object(values) = payload, let encoded = values["detailResource"] else { return payload }
    let resource = try JSONDecoder().decode(ToolDetailResource.self, from: JSONEncoder().encode(encoded))
    let update = values["sessionUpdate"]?.stringValue
    if update == "agent_message_patch",
      let text = values["text"]?.stringValue,
      let offset = values["offset"]?.intValue, let total = values["totalLength"]?.intValue,
      offset + text.utf16.count >= total
    {
      values.removeValue(forKey: "detailResource")
      return .object(values)
    }
    for metadata in resource.fields {
      let text = try await field(metadata, resource: resource)
      if update == "agent_message_patch", metadata.name == "text" {
        values["text"] = .string(text)
        values["offset"] = .number(0)
      } else if update == "plan_document", metadata.name == "text" {
        values["markdown"] = .string(text)
      } else {
        values[metadata.name] =
          metadata.encoding == "json"
          ? try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) : .string(text)
      }
    }
    values.removeValue(forKey: "detailResource")
    return .object(values)
  }
}

extension ServerSessionTransport {
  /// Initial and older pages publish complete message text once, before the
  /// renderer sees them. Hidden worked content retains its lazy turn contract.
  public func completeHistoryPage(
    _ page: TranscriptHistoryPage, before: String? = nil, limit: Int = 32
  ) async throws -> TranscriptHistoryPage {
    var page = page
    var changed: ToolDetailResource?
    while true {
      do { return try await resolveHistoryPage(page) } catch let ServerTranscriptContent.LoadError.changed(resource) {
        guard changed != resource else { throw ServerTranscriptContent.LoadError.changed(resource) }
        changed = resource
        try Task.checkCancellation()
        page = try await transcriptPage(before: before, limit: limit)
      }
    }
  }

  private func resolveHistoryPage(_ page: TranscriptHistoryPage) async throws -> TranscriptHistoryPage {
    let content = ServerTranscriptContent(transport: self)
    var page = page
    for index in page.conversation.indices {
      switch page.conversation[index] {
      case .user(var message):
        if let resource = message.textResource, let field = resource.fields.first(where: { $0.name == "text" }) {
          message.text = try await content.field(field, resource: resource)
          message.textResource = nil
          page.conversation[index] = .user(message)
        }
      case .assistant(var message):
        for entryIndex in message.turn.entries.indices {
          guard case let .text(id, _) = message.turn.entries[entryIndex],
            let resource = message.turn.textStates[":\(id)"]?.resource,
            let field = resource.fields.first(where: { $0.name == "text" })
          else { continue }
          let text = try await content.field(field, resource: resource)
          message.turn.entries[entryIndex] = .text(id: id, markdown: text)
          message.turn.textStates[":\(id)"]?.resource = nil
        }
        if let resource = message.turn.planResource, let field = resource.fields.first {
          message.turn.planDocument = try await content.field(field, resource: resource)
          message.turn.planResource = nil
        }
        page.conversation[index] = .assistant(message)
      }
    }
    return page
  }

  /// Drain materialized storage pages into one complete turn. No event-log
  /// replay, partial installs, or eviction is exposed to the transcript.
  public func transcriptDetails(itemId: String) async throws -> ServerTranscriptItemDetails {
    var changed: ToolDetailResource?
    while true {
      do { return try await completeTranscriptDetails(itemId: itemId) } catch let ServerTranscriptContent.LoadError
        .changed(resource)
      {
        guard changed != resource else { throw ServerTranscriptContent.LoadError.changed(resource) }
        changed = resource
        // A field was replaced while reading it. Restart from current metadata
        // rather than mixing generations in the document we publish.
        try Task.checkCancellation()
      }
    }
  }

  private func completeTranscriptDetails(itemId: String) async throws -> ServerTranscriptItemDetails {
    let content = ServerTranscriptContent(transport: self)
    var entries: [String: ServerTranscriptEntry] = [:]
    var cursor: String?
    var cursors: Set<String> = []
    var revision = 0
    var eventCursor: Int?
    repeat {
      try Task.checkCancellation()
      let page = try await client.transcriptItemDetails(id: sessionId, itemId: itemId, after: cursor)
      revision = max(revision, page.revision)
      eventCursor = min(eventCursor ?? page.eventCursor, page.eventCursor)
      for var entry in page.entries {
        if let existing = entries[entry.key], existing.revision >= entry.revision { continue }
        entry.payload = try await content.payload(entry.payload)
        entries[entry.key] = entry
      }
      cursor = page.nextAfter
      if let cursor, !cursors.insert(cursor).inserted { throw CodevisorServerClientError.invalidResponse }
    } while cursor != nil
    return ServerTranscriptItemDetails(
      itemId: itemId, revision: revision, eventCursor: eventCursor ?? 0,
      entries: entries.values.sorted { ($0.position, $0.key) < ($1.position, $1.key) })
  }
}
