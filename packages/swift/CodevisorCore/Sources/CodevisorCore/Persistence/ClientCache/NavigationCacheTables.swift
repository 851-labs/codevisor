import Foundation

struct NavigationCacheTables: Sendable {
  let database: ClientDatabase

  func write(
    _ snapshot: ServerNavigationSnapshot, over previous: ServerNavigationSnapshot?, machineId: String, at now: Date
  ) throws {
    try database.withTransaction {
      if previous == nil { try database.run(Self.deleteMachineSql, bindings: [.text(machineId)]) }
      try database.run(Self.upsertMachineSql, bindings: Self.machineBindings(snapshot, machineId: machineId, now: now))
      try Self.projects.write(snapshot, over: previous, machineId: machineId, in: database)
      try Self.workspaces.write(snapshot, over: previous, machineId: machineId, in: database)
      try Self.chats.write(snapshot, over: previous, machineId: machineId, in: database)
      try Self.panes.write(snapshot, over: previous, machineId: machineId, in: database)
      try Self.checkouts.write(snapshot, over: previous, machineId: machineId, in: database)
    }
  }

  func snapshot(machineId: String) throws -> ServerNavigationSnapshot? {
    guard let cursor = try eventCursor(machineId: machineId) else { return nil }

    return ServerNavigationSnapshot(
      eventCursor: cursor,
      projects: try Self.projects.read(machineId: machineId, from: database),
      sessions: try Self.chats.read(machineId: machineId, from: database),
      workspaces: try Self.workspaces.read(machineId: machineId, from: database),
      panes: try Self.panes.read(machineId: machineId, from: database),
      checkouts: try Self.checkouts.read(machineId: machineId, from: database))
  }

  func snapshots() throws -> [String: ServerNavigationSnapshot] {
    var snapshots: [String: ServerNavigationSnapshot] = [:]
    for machineId in try machineIds() {
      snapshots[machineId] = try snapshot(machineId: machineId)
    }
    return snapshots
  }

  func machineIds() throws -> [String] {
    try database.queryRows(Self.machineIdsSql, bindings: []) { $0.text(0) ?? "" }
  }

  func remove(machineId: String) throws {
    try database.run(Self.deleteMachineSql, bindings: [.text(machineId)])
  }

  private func eventCursor(machineId: String) throws -> Int? {
    try database.queryRows(Self.cursorSql, bindings: [.text(machineId)]) { Int($0.integer(0)) }.first
  }

  private static func machineBindings(
    _ snapshot: ServerNavigationSnapshot, machineId: String, now: Date
  ) -> [ClientDatabase.Binding] {
    [.text(machineId), .integer(Int64(snapshot.eventCursor)), .integer(Int64(now.timeIntervalSince1970))]
  }

  private static let projects = NavigationRecordTable<ServerProject>(
    table: "cache_projects", columnNames: ["name"], records: \.projects, id: \.id,
    columns: { [.text($0.name)] })

  private static let workspaces = NavigationRecordTable<ServerWorkspace>(
    table: "cache_workspaces",
    columnNames: ["project_id", "name", "is_archived", "sidebar_position", "updated_at"],
    records: \.workspaces, id: \.id,
    columns: { workspace in
      [
        .text(workspace.projectId), .text(workspace.name), .integer(workspace.isArchived ? 1 : 0),
        .optionalText(workspace.sidebarPosition), .optionalText(workspace.updatedAt),
      ]
    })

  private static let chats = NavigationRecordTable<ServerSession>(
    table: "cache_chats", columnNames: ["project_id", "workspace_id", "title", "updated_at"],
    records: \.sessions, id: \.id,
    columns: { chat in
      [.text(chat.projectId), .optionalText(chat.workspaceId), .text(chat.title), .optionalText(chat.updatedAt)]
    })

  private static let panes = NavigationRecordTable<ServerWorkspacePane>(
    table: "cache_panes", columnNames: ["workspace_id"], records: \.panes, id: \.id,
    columns: { [.text($0.workspaceId)] })

  private static let checkouts = NavigationRecordTable<ServerCheckout>(
    table: "cache_checkouts", columnNames: [], records: \.checkouts, id: \.id, columns: { _ in [] })

  private static let upsertMachineSql = """
    INSERT INTO cache_machines (machine_id, event_cursor, synced_at) VALUES (?, ?, ?)
    ON CONFLICT(machine_id) DO UPDATE SET event_cursor = excluded.event_cursor, synced_at = excluded.synced_at
    """
  private static let deleteMachineSql = "DELETE FROM cache_machines WHERE machine_id = ?"
  private static let cursorSql = "SELECT event_cursor FROM cache_machines WHERE machine_id = ?"
  private static let machineIdsSql = "SELECT machine_id FROM cache_machines ORDER BY machine_id"
}
