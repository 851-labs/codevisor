import Foundation
import SQLite3

struct ClientDatabaseRow {
  let statement: OpaquePointer

  func text(_ column: Int32) -> String? {
    guard let raw = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: raw)
  }

  func integer(_ column: Int32) -> Int64 {
    sqlite3_column_int64(statement, column)
  }

  func optionalInteger(_ column: Int32) -> Int64? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return integer(column)
  }

  func data(_ column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: count)
  }
}
