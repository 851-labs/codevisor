import CryptoKit
import Foundation

struct AttachmentCacheTables: Sendable {
  enum Variant: String, Sendable {
    case original
    case preview

    var nameColumn: String { self == .original ? "file_name" : "preview_name" }
    var bytesColumn: String { self == .original ? "file_bytes" : "preview_bytes" }
  }

  let database: ClientDatabase

  func noteSeen(in page: TranscriptPagePayload, chat: CachedChatKey, at now: Date) throws {
    for attachment in page.items.flatMap(\.attachments) {
      try database.run(
        Self.upsertSeenSql,
        bindings: chat.bindings + [
          .text(attachment.fileId), .text(attachment.name), .text(attachment.mimeType),
          .integer(Int64(attachment.sizeBytes)), .text(attachment.kind.rawValue), .integer(Self.seconds(now)),
        ])
    }
  }

  func recordFile(named fileName: String, bytes: Int, variant: Variant, file: CachedFileKey, at now: Date) throws {
    try database.withTransaction {
      try database.run(
        Self.insertPlaceholderSql,
        bindings: file.bindings + [
          .text(file.fileId), .integer(Int64(bytes)), .integer(Self.seconds(now)),
        ])
      try database.run(
        Self.recordFileSql(variant),
        bindings: [
          .text(fileName), .integer(Int64(bytes)), .integer(Self.seconds(now)),
        ] + file.bindings)
    }
  }

  func fileName(of file: CachedFileKey, variant: Variant) throws -> String? {
    try database.queryRows(Self.fileNameSql(variant), bindings: file.bindings) { $0.text(0) }.first ?? nil
  }

  func touch(_ file: CachedFileKey, at now: Date) throws {
    try database.run(Self.touchSql, bindings: [.integer(Self.seconds(now))] + file.bindings)
  }

  func forgetFile(_ file: CachedFileKey, variant: Variant) throws {
    try database.run(Self.forgetFileSql(variant), bindings: file.bindings)
  }

  static func fileName(for file: CachedFileKey, variant: Variant) -> String {
    let digest = SHA256.hash(data: Data("\(file.machineId)\n\(file.fileId)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined() + "." + variant.rawValue
  }

  private static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }

  private static func recordFileSql(_ variant: Variant) -> String {
    """
    UPDATE cache_attachments SET \(variant.nameColumn) = ?, \(variant.bytesColumn) = ?, opened_at = ?
    WHERE machine_id = ? AND file_id = ?
    """
  }

  private static func fileNameSql(_ variant: Variant) -> String {
    "SELECT \(variant.nameColumn) FROM cache_attachments WHERE machine_id = ? AND file_id = ?"
  }

  private static func forgetFileSql(_ variant: Variant) -> String {
    """
    UPDATE cache_attachments SET \(variant.nameColumn) = NULL, \(variant.bytesColumn) = 0
    WHERE machine_id = ? AND file_id = ?
    """
  }

  private static let upsertSeenSql = """
    INSERT INTO cache_attachments (machine_id, chat_id, file_id, name, mime_type, size_bytes, kind, seen_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(machine_id, file_id) DO UPDATE SET
        chat_id = excluded.chat_id,
        name = excluded.name,
        mime_type = excluded.mime_type,
        size_bytes = excluded.size_bytes,
        kind = excluded.kind,
        seen_at = excluded.seen_at
    """
  private static let insertPlaceholderSql = """
    INSERT INTO cache_attachments (machine_id, file_id, name, mime_type, size_bytes, kind, seen_at)
    VALUES (?, ?, ?, '', ?, 'file', ?)
    ON CONFLICT(machine_id, file_id) DO NOTHING
    """
  private static let touchSql = "UPDATE cache_attachments SET opened_at = ? WHERE machine_id = ? AND file_id = ?"
}
