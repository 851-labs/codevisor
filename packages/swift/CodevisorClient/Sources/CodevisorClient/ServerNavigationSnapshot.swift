import Foundation

public struct ServerNavigationSnapshot: Codable, Equatable, Sendable {
  public var eventCursor: Int
  public var projects: [ServerProject]
  public var sessions: [ServerSession]
  public var workspaces: [ServerWorkspace]
  public var panes: [ServerWorkspacePane]
  public var checkouts: [ServerCheckout]

  public init(
    eventCursor: Int, projects: [ServerProject], sessions: [ServerSession],
    workspaces: [ServerWorkspace], panes: [ServerWorkspacePane], checkouts: [ServerCheckout] = []
  ) {
    self.eventCursor = eventCursor
    self.projects = projects
    self.sessions = sessions
    self.workspaces = workspaces
    self.panes = panes
    self.checkouts = checkouts
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    projects = try container.decode([ServerProject].self, forKey: .projects)
    sessions = try container.decode([ServerSession].self, forKey: .sessions)
    workspaces = try container.decode([ServerWorkspace].self, forKey: .workspaces)
    panes = try container.decode([ServerWorkspacePane].self, forKey: .panes)
    checkouts = try container.decodeIfPresent([ServerCheckout].self, forKey: .checkouts) ?? []
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
  public var checkouts: [ServerCheckout]
  public var deleted: [Deletion]

  public init(
    eventCursor: Int, projects: [ServerProject], sessions: [ServerSession],
    workspaces: [ServerWorkspace], panes: [ServerWorkspacePane], checkouts: [ServerCheckout] = [],
    deleted: [Deletion]
  ) {
    self.eventCursor = eventCursor
    self.projects = projects
    self.sessions = sessions
    self.workspaces = workspaces
    self.panes = panes
    self.checkouts = checkouts
    self.deleted = deleted
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    projects = try container.decode([ServerProject].self, forKey: .projects)
    sessions = try container.decode([ServerSession].self, forKey: .sessions)
    workspaces = try container.decode([ServerWorkspace].self, forKey: .workspaces)
    panes = try container.decode([ServerWorkspacePane].self, forKey: .panes)
    checkouts = try container.decodeIfPresent([ServerCheckout].self, forKey: .checkouts) ?? []
    deleted = try container.decode([Deletion].self, forKey: .deleted)
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
      checkouts: merge(snapshot.checkouts, checkouts, table: "checkouts", id: { $0.id }))
  }
}

extension CodevisorServerClient {
  public func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    try await get("/v1/navigation")
  }
}
