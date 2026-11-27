import Foundation

struct TranscriptCacheTables: Sendable {
  static let maxItemsPerChat = 400

  let database: ClientDatabase

  func writeHead(_ page: TranscriptPagePayload, chat: CachedChatKey, opened: Bool, at now: Date) throws {
    try database.withTransaction {
      if let stored = try eventCursor(of: chat), stored > page.eventCursor { return }

      let keepsOlderItems = try continues(page, chat: chat)
      try database.run(
        Self.upsertTranscriptSql, bindings: Self.transcriptBindings(page, chat: chat, opened: opened, now: now))
      try deleteItems(replacedBy: page, chat: chat, through: Int.max, keepingOlder: keepsOlderItems)
      try upsertItems(of: page, chat: chat)
      try trimItems(of: chat)
      try AttachmentCacheTables(database: database).noteSeen(in: page, chat: chat, at: now)
    }
  }

  func writeOlder(_ page: TranscriptPagePayload, before cursor: String, chat: CachedChatKey, at now: Date) throws {
    try database.withTransaction {
      guard try hasBoundary(cursor, chat: chat) else { return }
      guard try itemCount(of: chat) + page.items.count <= Self.maxItemsPerChat else { return }

      try deleteItems(replacedBy: page, chat: chat, through: page.newestSequence, keepingOlder: true)
      try upsertItems(of: page, chat: chat)
      try AttachmentCacheTables(database: database).noteSeen(in: page, chat: chat, at: now)
    }
  }

  func page(of chat: CachedChatKey) throws -> Data? {
    guard let head = try head(of: chat) else { return nil }

    let items = try database.queryRows(Self.itemsSql, bindings: chat.bindings) { row in
      (payload: row.data(0), before: row.text(1))
    }
    return try TranscriptPagePayload.assemble(head: head, items: items.map(\.payload), nextBefore: items.first?.before)
  }

  func markOpened(_ chat: CachedChatKey, at now: Date) throws {
    try database.run(Self.markOpenedSql, bindings: [.integer(Int64(now.timeIntervalSince1970))] + chat.bindings)
  }

  func remove(_ chat: CachedChatKey) throws {
    try database.run(Self.deleteTranscriptSql, bindings: chat.bindings)
  }

  private func continues(_ page: TranscriptPagePayload, chat: CachedChatKey) throws -> Bool {
    guard let oldest = page.oldest else { return false }

    return try database.queryRows(Self.itemExistsSql, bindings: chat.bindings + [.text(oldest.id)]) { _ in true }
      .isEmpty == false
  }

  private func deleteItems(
    replacedBy page: TranscriptPagePayload, chat: CachedChatKey, through newest: Int, keepingOlder: Bool
  ) throws {
    guard let oldest = page.oldest, keepingOlder else {
      try database.run(Self.deleteItemsSql, bindings: chat.bindings)
      return
    }

    let kept = Set(page.items.map(\.id))
    let range: [ClientDatabase.Binding] = [.integer(Int64(oldest.sequence)), .integer(Int64(newest))]
    let inWindow = try database.queryRows(Self.itemIdsInRangeSql, bindings: chat.bindings + range) { $0.text(0) ?? "" }
    for id in inWindow where !kept.contains(id) {
      try database.run(Self.deleteItemSql, bindings: chat.bindings + [.text(id)])
    }
  }

  private func upsertItems(of page: TranscriptPagePayload, chat: CachedChatKey) throws {
    let oldestId = page.oldest?.id
    for item in page.items {
      let before = item.id == oldestId ? page.nextBefore : nil
      try database.run(
        Self.upsertItemSql,
        bindings: chat.bindings + [
          .text(item.id), .integer(Int64(item.sequence)), .optionalText(before), .blob(item.payload),
        ])
    }
  }

  private func trimItems(of chat: CachedChatKey) throws {
    let boundaries = try database.queryRows(Self.boundariesSql, bindings: chat.bindings) { row in
      TranscriptItemBoundary(sequence: Int(row.integer(0)), isPageStart: row.text(1) != nil)
    }
    guard let cut = TranscriptItemBoundary.cut(boundaries, keeping: Self.maxItemsPerChat) else { return }

    try database.run(Self.deleteOlderSql, bindings: chat.bindings + [.integer(Int64(cut))])
  }

  private func eventCursor(of chat: CachedChatKey) throws -> Int? {
    try database.queryRows(Self.cursorSql, bindings: chat.bindings) { Int($0.integer(0)) }.first
  }

  private func head(of chat: CachedChatKey) throws -> Data? {
    try database.queryRows(Self.headSql, bindings: chat.bindings) { $0.data(0) }.first
  }

  private func hasBoundary(_ cursor: String, chat: CachedChatKey) throws -> Bool {
    try !database.queryRows(Self.boundaryExistsSql, bindings: chat.bindings + [.text(cursor)]) { _ in true }.isEmpty
  }

  private func itemCount(of chat: CachedChatKey) throws -> Int {
    try database.queryRows(Self.countSql, bindings: chat.bindings) { Int($0.integer(0)) }.first ?? 0
  }

  private static func transcriptBindings(
    _ page: TranscriptPagePayload, chat: CachedChatKey, opened: Bool, now: Date
  ) -> [ClientDatabase.Binding] {
    let seconds = Int64(now.timeIntervalSince1970)
    return chat.bindings + [
      .integer(Int64(page.eventCursor)), .blob(page.head), .optionalBlob(page.runtime), .integer(seconds),
      .integer(seconds), .integer(opened ? 1 : 0),
    ]
  }

  private static let upsertTranscriptSql = """
    INSERT INTO cache_transcripts (machine_id, chat_id, event_cursor, head, runtime, fetched_at, opened_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(machine_id, chat_id) DO UPDATE SET
        event_cursor = excluded.event_cursor,
        head = excluded.head,
        runtime = COALESCE(excluded.runtime, runtime),
        fetched_at = excluded.fetched_at,
        opened_at = CASE WHEN ? = 1 THEN excluded.opened_at ELSE opened_at END
    """
  private static let upsertItemSql = """
    INSERT INTO cache_transcript_items (machine_id, chat_id, item_id, sequence, before_cursor, payload)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(machine_id, chat_id, item_id) DO UPDATE SET
        sequence = excluded.sequence,
        before_cursor = COALESCE(excluded.before_cursor, before_cursor),
        payload = excluded.payload
    """
  private static let itemsSql = """
    SELECT payload, before_cursor FROM cache_transcript_items
    WHERE machine_id = ? AND chat_id = ? ORDER BY sequence
    """
  private static let itemIdsInRangeSql = """
    SELECT item_id FROM cache_transcript_items
    WHERE machine_id = ? AND chat_id = ? AND sequence >= ? AND sequence <= ?
    """
  private static let boundariesSql = """
    SELECT sequence, before_cursor FROM cache_transcript_items
    WHERE machine_id = ? AND chat_id = ? ORDER BY sequence DESC
    """
  private static let itemExistsSql =
    "SELECT 1 FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ? AND item_id = ?"
  private static let boundaryExistsSql = """
    SELECT 1 FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ? AND before_cursor = ?
    """
  private static let countSql = "SELECT COUNT(*) FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ?"
  private static let deleteItemSql =
    "DELETE FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ? AND item_id = ?"
  private static let deleteItemsSql = "DELETE FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ?"
  private static let deleteOlderSql =
    "DELETE FROM cache_transcript_items WHERE machine_id = ? AND chat_id = ? AND sequence < ?"
  private static let cursorSql = "SELECT event_cursor FROM cache_transcripts WHERE machine_id = ? AND chat_id = ?"
  private static let headSql = "SELECT head FROM cache_transcripts WHERE machine_id = ? AND chat_id = ?"
  private static let markOpenedSql = "UPDATE cache_transcripts SET opened_at = ? WHERE machine_id = ? AND chat_id = ?"
  private static let deleteTranscriptSql = "DELETE FROM cache_transcripts WHERE machine_id = ? AND chat_id = ?"
}
