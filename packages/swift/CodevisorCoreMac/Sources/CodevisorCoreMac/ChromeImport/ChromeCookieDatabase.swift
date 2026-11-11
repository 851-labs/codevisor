import Foundation
import SQLite3

final class ChromeCookieDatabase {
  private var handle: OpaquePointer?

  init(url: URL) throws {
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      sqlite3_close(handle)
      throw ChromeImportError.unreadable
    }
  }

  deinit { sqlite3_close(handle) }

  func strings(_ sql: String) -> [String] {
    query(sql) { statement in Self.text(statement, 0) }
  }

  func rows(_ sql: String) -> [ChromeCookieRow] {
    query(sql) { statement in
      ChromeCookieRow(
        host: Self.text(statement, 0), name: Self.text(statement, 1), value: Self.text(statement, 2),
        encryptedValue: Self.blob(statement, 3), path: Self.text(statement, 4),
        expiresUTC: sqlite3_column_int64(statement, 5), hasExpires: sqlite3_column_int(statement, 6) != 0,
        secure: sqlite3_column_int(statement, 7) != 0, httpOnly: sqlite3_column_int(statement, 8) != 0,
        sameSite: Int(sqlite3_column_int(statement, 9)), lastUpdateUTC: sqlite3_column_int64(statement, 10))
    }
  }

  private func query<Row>(_ sql: String, row: (OpaquePointer) -> Row) -> [Row] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }

    var rows: [Row] = []
    while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
    return rows
  }

  private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
  }

  private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
  }
}
