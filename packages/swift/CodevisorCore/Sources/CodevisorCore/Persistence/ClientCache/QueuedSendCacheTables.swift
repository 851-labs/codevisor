import Foundation

struct QueuedSendCacheTables: Sendable {
  let database: ClientDatabase

  func replace(_ sends: [CachedQueuedSend], in chat: CachedChatKey, at now: Date) throws {
    try database.withTransaction {
      let kept = Set(sends.map { $0.messageId.uuidString.lowercased() })
      for stale in try messageIds(in: chat) where !kept.contains(stale) {
        try database.run(Self.deleteSql, bindings: [.text(stale)])
      }
      for send in sends {
        try database.run(Self.upsertSql, bindings: try Self.bindings(send, chat: chat, now: now))
      }
    }
  }

  func messageIds(in chat: CachedChatKey) throws -> [String] {
    try database.queryRows(Self.idsSql, bindings: chat.bindings) { $0.text(0) ?? "" }
  }

  private static func bindings(
    _ send: CachedQueuedSend, chat: CachedChatKey, now: Date
  ) throws -> [ClientDatabase.Binding] {
    [
      .text(send.messageId.uuidString.lowercased()), .text(chat.machineId), .text(chat.chatId), .text(send.text),
      .blob(try JSONEncoder().encode(send.attachments)), .text(send.route), .text(send.state),
      .optionalText(send.failure), .integer(Int64(now.timeIntervalSince1970)),
    ]
  }

  private static let upsertSql = """
    INSERT INTO cache_queued_sends
        (message_id, machine_id, chat_id, text, attachments, route, state, failure, queued_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(message_id) DO UPDATE SET
        text = excluded.text,
        attachments = excluded.attachments,
        route = excluded.route,
        state = excluded.state,
        failure = excluded.failure
    """
  private static let idsSql = "SELECT message_id FROM cache_queued_sends WHERE machine_id = ? AND chat_id = ?"
  private static let deleteSql = "DELETE FROM cache_queued_sends WHERE message_id = ?"
}
