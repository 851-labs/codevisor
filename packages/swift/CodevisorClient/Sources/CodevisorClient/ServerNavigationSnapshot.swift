import Foundation

/// All navigation state and its stream boundary from one database transaction.
public struct ServerNavigationSnapshot: Codable, Equatable, Sendable {
  public var eventCursor: Int
  public var projects: [ServerProject]
  public var sessions: [ServerSession]
  public var workspaces: [ServerWorkspace]
  public var panes: [ServerWorkspacePane]
  /// Replicated sidebar records (folders and settings) this machine holds.
  public var records: ServerNavigationRecords

  public init(
    eventCursor: Int, projects: [ServerProject], sessions: [ServerSession],
    workspaces: [ServerWorkspace], panes: [ServerWorkspacePane],
    records: ServerNavigationRecords = ServerNavigationRecords()
  ) {
    self.eventCursor = eventCursor
    self.projects = projects
    self.sessions = sessions
    self.workspaces = workspaces
    self.panes = panes
    self.records = records
  }

  private enum CodingKeys: String, CodingKey {
    case eventCursor, projects, sessions, workspaces, panes, folders, settings
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    projects = try container.decode([ServerProject].self, forKey: .projects)
    sessions = try container.decode([ServerSession].self, forKey: .sessions)
    workspaces = try container.decode([ServerWorkspace].self, forKey: .workspaces)
    panes = try container.decode([ServerWorkspacePane].self, forKey: .panes)
    // Servers omit records while they hold none, and older servers have none.
    records = ServerNavigationRecords(
      folders: try container.decodeIfPresent([ServerNavigationFolder].self, forKey: .folders) ?? [],
      settings: try container.decodeIfPresent([ServerNavigationSetting].self, forKey: .settings) ?? [])
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(eventCursor, forKey: .eventCursor)
    try container.encode(projects, forKey: .projects)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encode(panes, forKey: .panes)
    try container.encode(records.folders, forKey: .folders)
    try container.encode(records.settings, forKey: .settings)
  }
}

public struct ServerNavigationDelta: Codable, Equatable, Sendable {
  public struct Deletion: Codable, Equatable, Sendable {
    public var table: String
    public var id: String
  }
  public var eventCursor: Int
  public var projects: [ServerProject]
  public var sessions: [ServerSession]
  public var workspaces: [ServerWorkspace]
  public var panes: [ServerWorkspacePane]
  public var deleted: [Deletion]
  public var records: ServerNavigationRecords

  private enum CodingKeys: String, CodingKey {
    case eventCursor, projects, sessions, workspaces, panes, deleted, folders, settings
  }

  public init(
    eventCursor: Int, projects: [ServerProject] = [], sessions: [ServerSession] = [],
    workspaces: [ServerWorkspace] = [], panes: [ServerWorkspacePane] = [], deleted: [Deletion] = [],
    records: ServerNavigationRecords = ServerNavigationRecords()
  ) {
    self.eventCursor = eventCursor
    self.projects = projects
    self.sessions = sessions
    self.workspaces = workspaces
    self.panes = panes
    self.deleted = deleted
    self.records = records
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    projects = try container.decode([ServerProject].self, forKey: .projects)
    sessions = try container.decode([ServerSession].self, forKey: .sessions)
    workspaces = try container.decode([ServerWorkspace].self, forKey: .workspaces)
    panes = try container.decode([ServerWorkspacePane].self, forKey: .panes)
    deleted = try container.decode([Deletion].self, forKey: .deleted)
    records = ServerNavigationRecords(
      folders: try container.decodeIfPresent([ServerNavigationFolder].self, forKey: .folders) ?? [],
      settings: try container.decodeIfPresent([ServerNavigationSetting].self, forKey: .settings) ?? [])
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(eventCursor, forKey: .eventCursor)
    try container.encode(projects, forKey: .projects)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encode(panes, forKey: .panes)
    try container.encode(deleted, forKey: .deleted)
    try container.encode(records.folders, forKey: .folders)
    try container.encode(records.settings, forKey: .settings)
  }

  public func applying(to snapshot: ServerNavigationSnapshot) -> ServerNavigationSnapshot {
    guard eventCursor > snapshot.eventCursor else { return snapshot }
    func merge<T>(_ current: [T], _ changes: [T], table: String, id: (T) -> String) -> [T] {
      let removed = Set(deleted.filter { $0.table == table }.map { $0.id.lowercased() })
      var records = Dictionary(current.map { (id($0).lowercased(), $0) }, uniquingKeysWith: { _, new in new })
      for key in removed { records.removeValue(forKey: key) }
      for record in changes { records[id(record).lowercased()] = record }
      return records.sorted { $0.key < $1.key }.map(\.value)
    }
    return ServerNavigationSnapshot(
      eventCursor: eventCursor,
      projects: merge(snapshot.projects, projects, table: "projects", id: { $0.id }),
      sessions: merge(snapshot.sessions, sessions, table: "sessions", id: { $0.id }),
      workspaces: merge(snapshot.workspaces, workspaces, table: "workspaces", id: { $0.id }),
      panes: merge(snapshot.panes, panes, table: "workspace_panes", id: { $0.id }),
      records: snapshot.records.merging(records))
  }
}

extension CodevisorServerClient {
  public func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    try await get("/v1/navigation")
  }
}
