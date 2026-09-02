import CryptoKit
import Foundation
import SQLite3

public struct ClientDatabaseError: Error, LocalizedError, Sendable {
  public let operation: String
  public let detail: String

  public var errorDescription: String? {
    "Client database \(operation) failed: \(detail)"
  }
}

public struct ClientSchemaMigration: Sendable {
  public let id: Int
  public let name: String
  public let sql: String

  public init(id: Int, name: String, sql: String) {
    self.id = id
    self.name = name
    self.sql = sql
  }

  fileprivate var checksum: String {
    let digest = SHA256.hash(data: Data("\(id)\n\(name)\n\(sql)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

public protocol ClientDataResetting: Sendable {
  func resetClientData() throws
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The one SQLite connection used by a native client installation.
///
/// The public repositories remain synchronous today, so the connection is
/// serialized by a recursive lock. This also lets a transaction call the
/// ordinary value helpers without deadlocking. WAL keeps readers cheap and
/// all multi-row migration work uses explicit transactions.
public final class ClientDatabase: @unchecked Sendable {
  public static let fileName = "client.sqlite"

  public let url: URL

  let lock = NSRecursiveLock()
  private var handle: OpaquePointer?

  public init(url: URL, fileManager: FileManager = .default) throws {
    self.url = url
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path,
      &opened,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      let detail =
        opened.map { String(cString: sqlite3_errmsg($0)) }
        ?? "SQLite returned \(result)"
      if let opened { sqlite3_close(opened) }
      throw ClientDatabaseError(operation: "open", detail: detail)
    }
    handle = opened

    do {
      try execute("PRAGMA journal_mode = WAL;")
      try execute("PRAGMA foreign_keys = ON;")
      try execute("PRAGMA synchronous = NORMAL;")
      try execute("PRAGMA busy_timeout = 5000;")
    } catch {
      sqlite3_close(opened)
      handle = nil
      throw error
    }
  }

  deinit {
    lock.withLock {
      if let handle {
        sqlite3_close(handle)
        self.handle = nil
      }
    }
  }

  public func migrate(
    migrations: [ClientSchemaMigration] = ClientDatabaseMigrations.all,
    backupURL: URL? = nil
  ) throws {
    try lock.withLock {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS client_schema_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            checksum TEXT NOT NULL,
            applied_at TEXT NOT NULL
        );
        """
      )

      let applied = try appliedMigrations()
      let ordered = migrations.sorted { $0.id < $1.id }
      guard ordered.map(\.id) == migrations.map(\.id),
        Set(ordered.map(\.id)).count == ordered.count
      else {
        throw ClientDatabaseError(
          operation: "migration validation",
          detail: "Migration ids must be unique and declared in ascending order"
        )
      }

      let declaredIDs = ordered.map(\.id)
      let appliedIDs = applied.keys.sorted()
      guard Array(declaredIDs.prefix(appliedIDs.count)) == appliedIDs else {
        throw ClientDatabaseError(
          operation: "migration validation",
          detail: "Database schema is newer than this client or has a migration gap"
        )
      }

      for migration in ordered {
        if let existing = applied[migration.id] {
          guard existing.name == migration.name,
            existing.checksum == migration.checksum
          else {
            throw ClientDatabaseError(
              operation: "migration validation",
              detail: "Applied migration \(migration.id) was edited"
            )
          }
        }
      }

      let pending = ordered.filter { applied[$0.id] == nil }
      if !applied.isEmpty, !pending.isEmpty, let backupURL {
        try backup(to: backupURL)
      }

      for migration in pending {
        try withTransaction {
          try execute(migration.sql)
          try executePrepared(
            """
            INSERT INTO client_schema_migrations
                (id, name, checksum, applied_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
              .integer(Int64(migration.id)),
              .text(migration.name),
              .text(migration.checksum),
              .text(Self.timestamp()),
            ]
          )
          try assertForeignKeys()
        }
      }
      try assertIntegrity()
    }
  }

  public func withTransaction<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      try execute("BEGIN IMMEDIATE;")
      do {
        let result = try body()
        try execute("COMMIT;")
        return result
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  public func assertHealthy() throws {
    try lock.withLock {
      try assertForeignKeys()
      try assertIntegrity()
    }
  }

  public func backup(to destination: URL) throws {
    try lock.withLock {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? FileManager.default.removeItem(at: destination)

      var destinationHandle: OpaquePointer?
      guard sqlite3_open(destination.path, &destinationHandle) == SQLITE_OK,
        let destinationHandle
      else {
        if let destinationHandle { sqlite3_close(destinationHandle) }
        throw ClientDatabaseError(
          operation: "backup",
          detail: "Could not open \(destination.path)"
        )
      }
      defer { sqlite3_close(destinationHandle) }

      guard let handle,
        let backup = sqlite3_backup_init(destinationHandle, "main", handle, "main")
      else {
        throw makeError(operation: "backup initialization")
      }
      defer { sqlite3_backup_finish(backup) }

      let result = sqlite3_backup_step(backup, -1)
      guard result == SQLITE_DONE else {
        throw ClientDatabaseError(
          operation: "backup",
          detail: String(cString: sqlite3_errmsg(destinationHandle))
        )
      }
    }
  }

  func execute(_ sql: String) throws {
    guard let handle else {
      throw ClientDatabaseError(operation: "execute", detail: "Database is closed")
    }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let detail =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(handle))
      sqlite3_free(errorMessage)
      throw ClientDatabaseError(operation: "execute", detail: detail)
    }
  }

  enum Binding {
    case blob(Data)
    case integer(Int64)
    case null
    case text(String)
  }

  func executePrepared(_ sql: String, bindings: [Binding]) throws {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw makeError(operation: "write")
    }
  }

  func queryData(_ sql: String, bindings: [Binding]) throws -> Data? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else { throw makeError(operation: "read") }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  func queryText(_ sql: String, bindings: [Binding]) throws -> String? {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(bindings, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else { throw makeError(operation: "read") }
    guard let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
  }

  private func appliedMigrations() throws -> [Int: (name: String, checksum: String)] {
    let statement = try prepare(
      "SELECT id, name, checksum FROM client_schema_migrations ORDER BY id"
    )
    defer { sqlite3_finalize(statement) }
    var result: [Int: (name: String, checksum: String)] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      let id = Int(sqlite3_column_int64(statement, 0))
      guard let rawName = sqlite3_column_text(statement, 1),
        let rawChecksum = sqlite3_column_text(statement, 2)
      else {
        throw ClientDatabaseError(
          operation: "migration read",
          detail: "Migration \(id) has invalid metadata"
        )
      }
      result[id] = (String(cString: rawName), String(cString: rawChecksum))
    }
    return result
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let handle else {
      throw ClientDatabaseError(operation: "prepare", detail: "Database is closed")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw makeError(operation: "prepare")
    }
    return statement
  }

  private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case let .blob(data):
        result = data.withUnsafeBytes { bytes in
          sqlite3_bind_blob(
            statement,
            index,
            bytes.baseAddress,
            Int32(bytes.count),
            sqliteTransient
          )
        }
      case let .integer(value):
        result = sqlite3_bind_int64(statement, index, value)
      case .null:
        result = sqlite3_bind_null(statement, index)
      case let .text(value):
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
      }
      guard result == SQLITE_OK else {
        throw makeError(operation: "bind")
      }
    }
  }

  private func assertForeignKeys() throws {
    let statement = try prepare("PRAGMA foreign_key_check;")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw ClientDatabaseError(
        operation: "foreign-key check",
        detail: "Migration left a foreign-key violation"
      )
    }
  }

  private func assertIntegrity() throws {
    let result = try queryText("PRAGMA integrity_check;", bindings: [])
    guard result == "ok" else {
      throw ClientDatabaseError(
        operation: "integrity check",
        detail: result ?? "No result"
      )
    }
  }

  private func makeError(operation: String) -> ClientDatabaseError {
    let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed"
    return ClientDatabaseError(operation: operation, detail: detail)
  }

  static func timestamp() -> String {
    Date().ISO8601Format(.iso8601(timeZone: .gmt))
  }
}

public enum ClientDatabaseMigrations {
  public static let all: [ClientSchemaMigration] = [
    ClientSchemaMigration(
      id: 1,
      name: "initial client persistence",
      sql:
        """
        CREATE TABLE client_values (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_preferences (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_quarantine (
            id TEXT PRIMARY KEY,
            original_key TEXT NOT NULL,
            value BLOB NOT NULL,
            quarantined_at TEXT NOT NULL
        );

        CREATE TABLE client_blob_assets (
            key TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            digest TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_data_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('running', 'completed', 'failed')),
            cursor TEXT,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            last_error TEXT
        );

        CREATE TABLE client_cleanup_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('running', 'completed', 'failed')),
            cursor TEXT,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            last_error TEXT
        );

        CREATE TABLE client_migration_artifacts (
            migration_id INTEGER NOT NULL,
            source TEXT NOT NULL,
            digest TEXT NOT NULL,
            imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN (0, 1)),
            cleaned INTEGER NOT NULL DEFAULT 0 CHECK(cleaned IN (0, 1)),
            updated_at TEXT NOT NULL,
            PRIMARY KEY (migration_id, source)
        );

        CREATE TABLE client_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
  ]
}
