import Foundation

struct NavigationRecordTable<Record: Codable & Equatable & Sendable>: Sendable {
  let records: @Sendable (ServerNavigationSnapshot) -> [Record]
  let id: @Sendable (Record) -> String
  let columns: @Sendable (Record) -> [ClientDatabase.Binding]
  let upsertSql: String
  let deleteSql: String
  let selectSql: String

  init(
    table: String,
    columnNames: [String],
    records: @escaping @Sendable (ServerNavigationSnapshot) -> [Record],
    id: @escaping @Sendable (Record) -> String,
    columns: @escaping @Sendable (Record) -> [ClientDatabase.Binding]
  ) {
    self.records = records
    self.id = id
    self.columns = columns
    let names = ["machine_id", "id"] + columnNames + ["payload"]
    let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
    upsertSql = "INSERT OR REPLACE INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))"
    deleteSql = "DELETE FROM \(table) WHERE machine_id = ? AND id = ?"
    selectSql = "SELECT payload FROM \(table) WHERE machine_id = ?"
  }

  func write(
    _ snapshot: ServerNavigationSnapshot, over previous: ServerNavigationSnapshot?, machineId: String,
    in database: ClientDatabase
  ) throws {
    let changes = NavigationRecordChanges(new: records(snapshot), old: previous.map(records) ?? [], id: id)
    for record in changes.upserts {
      try database.run(upsertSql, bindings: bindings(record, machineId: machineId))
    }
    for removedId in changes.removedIds {
      try database.run(deleteSql, bindings: [.text(machineId), .text(removedId)])
    }
  }

  func read(machineId: String, from database: ClientDatabase) throws -> [Record] {
    let decoder = JSONDecoder()
    let records = try database.queryRows(selectSql, bindings: [.text(machineId)]) { row in
      try decoder.decode(Record.self, from: row.data(0))
    }
    return NavigationRecordChanges.ordered(records, id: id)
  }

  private func bindings(_ record: Record, machineId: String) throws -> [ClientDatabase.Binding] {
    [.text(machineId), .text(id(record))] + columns(record) + [.blob(try JSONEncoder().encode(record))]
  }
}
