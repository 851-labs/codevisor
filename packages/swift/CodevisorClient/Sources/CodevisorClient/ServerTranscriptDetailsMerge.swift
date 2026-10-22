import Foundation

nonisolated struct ServerTranscriptDetailsMerge {
  let itemId: String
  private var entries: [String: ServerTranscriptEntry] = [:]
  private var revision = 0
  private var eventCursor: Int?
  private var cursors: Set<String> = []

  init(itemId: String) {
    self.itemId = itemId
  }

  var details: ServerTranscriptItemDetails {
    ServerTranscriptItemDetails(
      itemId: itemId, revision: revision, eventCursor: eventCursor ?? 0,
      entries: entries.values.sorted { ($0.position, $0.key) < ($1.position, $1.key) })
  }

  mutating func recordVersions(of page: ServerTranscriptItemDetails) {
    revision = max(revision, page.revision)
    eventCursor = min(eventCursor ?? page.eventCursor, page.eventCursor)
  }

  func needs(_ entry: ServerTranscriptEntry) -> Bool {
    guard let existing = entries[entry.key] else { return true }
    return !(existing.revision >= entry.revision)
  }

  mutating func add(_ entry: ServerTranscriptEntry) {
    entries[entry.key] = entry
  }

  mutating func advance(to cursor: String?) throws -> String? {
    guard let cursor else { return nil }
    guard cursors.insert(cursor).inserted else { throw CodevisorServerClientError.invalidResponse }
    return cursor
  }
}
