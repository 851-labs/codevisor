import Foundation

struct ClientCacheTrim: Sendable {
  struct StoredFile: Sendable {
    let key: CachedFileKey
    let name: String
    let bytes: Int
  }

  let database: ClientDatabase
  let limits: ClientCacheLimits

  func run(at now: Date) throws -> [String] {
    try database.withTransaction {
      try removeTranscripts(openedBefore: now.addingTimeInterval(-limits.transcriptAge))
      try removeTranscriptsOverBudget()
      try removeOrphanedTranscripts()
      try database.run(Self.deleteOldSendsSql, bindings: [Self.seconds(now.addingTimeInterval(-limits.queuedSendAge))])
      let expired = try filesToRemove(usedBefore: now.addingTimeInterval(-limits.fileAge))
      try forget(expired)
      try database.run(Self.deleteUnusedAttachmentsSql, bindings: [])
      return expired.map(\.name)
    }
  }

  private func removeTranscripts(openedBefore cutoff: Date) throws {
    try database.run(Self.deleteOldTranscriptsSql, bindings: [Self.seconds(cutoff)])
  }

  private func removeTranscriptsOverBudget() throws {
    let sizes = try database.queryRows(Self.transcriptSizesSql, bindings: []) { row in
      (chat: [ClientDatabase.Binding.text(row.text(0) ?? ""), .text(row.text(1) ?? "")], bytes: Int(row.integer(2)))
    }
    var total = sizes.reduce(0) { $0 + $1.bytes }
    for transcript in sizes where total > limits.transcriptBytes {
      try database.run(Self.deleteTranscriptSql, bindings: transcript.chat)
      total -= transcript.bytes
    }
  }

  private func removeOrphanedTranscripts() throws {
    try database.run(Self.deleteOrphanedTranscriptsSql, bindings: [])
  }

  private func filesToRemove(usedBefore cutoff: Date) throws -> [StoredFile] {
    let files = try database.queryRows(Self.filesSql, bindings: []) { row in
      (file: Self.storedFile(row), usedAt: row.integer(3))
    }
    var total = files.reduce(0) { $0 + $1.file.bytes }
    var removed: [StoredFile] = []
    for entry in files where entry.usedAt < Int64(cutoff.timeIntervalSince1970) || total > limits.fileBytes {
      removed.append(entry.file)
      total -= entry.file.bytes
    }
    return removed
  }

  private func forget(_ files: [StoredFile]) throws {
    for file in files {
      try database.run(Self.forgetFileSql, bindings: [.text(file.name)] + file.key.bindings)
    }
  }

  private static func storedFile(_ row: ClientDatabaseRow) -> StoredFile {
    StoredFile(
      key: CachedFileKey(machineId: row.text(0) ?? "", fileId: row.text(1) ?? ""), name: row.text(2) ?? "",
      bytes: Int(row.integer(4)))
  }

  private static func seconds(_ date: Date) -> ClientDatabase.Binding { .integer(Int64(date.timeIntervalSince1970)) }

  private static let deleteOldTranscriptsSql = "DELETE FROM cache_transcripts WHERE opened_at < ?"
  private static let transcriptSizesSql = """
    SELECT t.machine_id, t.chat_id,
        length(t.head) + COALESCE((SELECT SUM(length(i.payload)) FROM cache_transcript_items i
            WHERE i.machine_id = t.machine_id AND i.chat_id = t.chat_id), 0)
    FROM cache_transcripts t ORDER BY t.opened_at
    """
  private static let deleteTranscriptSql = "DELETE FROM cache_transcripts WHERE machine_id = ? AND chat_id = ?"
  private static let deleteOrphanedTranscriptsSql = """
    DELETE FROM cache_transcripts
    WHERE machine_id IN (SELECT machine_id FROM cache_machines)
      AND NOT EXISTS (SELECT 1 FROM cache_chats c
          WHERE c.machine_id = cache_transcripts.machine_id AND lower(c.id) = cache_transcripts.chat_id)
    """
  private static let deleteOldSendsSql = "DELETE FROM cache_queued_sends WHERE queued_at < ?"
  private static let filesSql = """
    SELECT machine_id, file_id, name, used_at, bytes FROM (
        SELECT machine_id, file_id, file_name AS name, COALESCE(opened_at, seen_at) AS used_at, file_bytes AS bytes
        FROM cache_attachments WHERE file_name IS NOT NULL
        UNION ALL
        SELECT machine_id, file_id, preview_name, COALESCE(opened_at, seen_at), preview_bytes
        FROM cache_attachments WHERE preview_name IS NOT NULL
    ) ORDER BY used_at
    """
  private static let forgetFileSql = """
    UPDATE cache_attachments SET
        file_name = CASE WHEN file_name = ?1 THEN NULL ELSE file_name END,
        file_bytes = CASE WHEN file_name = ?1 THEN 0 ELSE file_bytes END,
        preview_name = CASE WHEN preview_name = ?1 THEN NULL ELSE preview_name END,
        preview_bytes = CASE WHEN preview_name = ?1 THEN 0 ELSE preview_bytes END
    WHERE machine_id = ?2 AND file_id = ?3
    """
  private static let deleteUnusedAttachmentsSql = """
    DELETE FROM cache_attachments
    WHERE file_name IS NULL AND preview_name IS NULL
      AND NOT EXISTS (SELECT 1 FROM cache_transcripts t
          WHERE t.machine_id = cache_attachments.machine_id AND t.chat_id = cache_attachments.chat_id)
    """
}
