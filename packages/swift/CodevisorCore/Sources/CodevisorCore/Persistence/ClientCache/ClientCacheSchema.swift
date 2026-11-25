import Foundation

enum ClientCacheSchema {
  static let version = 1

  static let tables = [
    "cache_queued_sends", "cache_attachments", "cache_transcript_items", "cache_transcripts",
    "cache_checkouts", "cache_panes", "cache_chats", "cache_workspaces", "cache_projects", "cache_machines",
  ]

  static func prepare(_ database: ClientDatabase) throws {
    try database.run(createMetadataSql, bindings: [])
    guard try storedVersion(in: database) != version else { return }

    try rebuild(database)
  }

  static func rebuild(_ database: ClientDatabase) throws {
    try database.withTransaction {
      for table in try existingCacheTables(in: database) {
        try database.execute(dropTableSql(table))
      }
      try database.execute(ClientCacheTables.createSql)
      try database.run(writeVersionSql, bindings: [.text(versionKey), .text(String(version))])
    }
  }

  private static let versionKey = "client_cache.schema_version"

  private static func storedVersion(in database: ClientDatabase) throws -> Int? {
    try database.queryText(readVersionSql, bindings: [.text(versionKey)]).flatMap(Int.init)
  }

  private static func existingCacheTables(in database: ClientDatabase) throws -> [String] {
    let present = Set(try database.queryRows(cacheTablesSql, bindings: []) { $0.text(0) ?? "" })
    let known = tables.filter(present.contains)
    return known + present.subtracting(known).sorted()
  }

  private static func dropTableSql(_ table: String) -> String {
    "DROP TABLE IF EXISTS \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\";"
  }

  private static let createMetadataSql =
    "CREATE TABLE IF NOT EXISTS client_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
  private static let readVersionSql = "SELECT value FROM client_metadata WHERE key = ?"
  private static let writeVersionSql = """
    INSERT INTO client_metadata (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    """
  private static let cacheTablesSql =
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cache\\_%' ESCAPE '\\'"
}
