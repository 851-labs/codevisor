import Foundation

public struct ServerBotProject: Codable, Equatable, Hashable, Sendable {
  public var projectId: String
  public var folderName: String
  public var branch: String
  public var path: String

  public init(projectId: String, folderName: String, branch: String, path: String) {
    self.projectId = projectId
    self.folderName = folderName
    self.branch = branch
    self.path = path
  }
}

public struct ServerBot: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: String
  public var serverId: String
  public var name: String
  public var symbolName: String
  public var mascot: ServerBotMascot?
  public var harnessId: String
  public var projectId: String
  public var sessionId: String
  public var workspaceId: String
  public var rootPath: String
  public var projects: [ServerBotProject]
  public var isArchived: Bool?
  public var createdAt: String
  public var updatedAt: String?

  public init(
    id: String,
    serverId: String,
    name: String,
    symbolName: String,
    mascot: ServerBotMascot? = nil,
    harnessId: String,
    projectId: String,
    sessionId: String,
    workspaceId: String,
    rootPath: String,
    projects: [ServerBotProject],
    isArchived: Bool? = nil,
    createdAt: String,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.serverId = serverId
    self.name = name
    self.symbolName = symbolName
    self.mascot = mascot
    self.harnessId = harnessId
    self.projectId = projectId
    self.sessionId = sessionId
    self.workspaceId = workspaceId
    self.rootPath = rootPath
    self.projects = projects
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ServerCreateBotRequest: Encodable, Equatable, Sendable {
  public var id: String?
  public var name: String
  public var symbolName: String
  public var mascot: ServerBotMascot?
  public var harnessId: String
  public var configSelections: [String: String]?
  public var projectIds: [String]

  public init(
    id: String? = nil,
    name: String,
    symbolName: String,
    mascot: ServerBotMascot? = nil,
    harnessId: String,
    configSelections: [String: String]? = nil,
    projectIds: [String]
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.mascot = mascot
    self.harnessId = harnessId
    self.configSelections = configSelections
    self.projectIds = projectIds
  }
}

public struct ServerForkBotRequest: Encodable, Equatable, Sendable {
  public var id: String?
  public var name: String
  public var mascot: ServerBotMascot?
  public var harnessId: String
  public var configSelections: [String: String]?
  public var moveAgents: Bool

  public init(
    id: String? = nil,
    name: String,
    mascot: ServerBotMascot? = nil,
    harnessId: String,
    configSelections: [String: String]? = nil,
    moveAgents: Bool
  ) {
    self.id = id
    self.name = name
    self.mascot = mascot
    self.harnessId = harnessId
    self.configSelections = configSelections
    self.moveAgents = moveAgents
  }
}

public struct ServerAddBotProjectRequest: Encodable, Equatable, Sendable {
  public var projectId: String

  public init(projectId: String) {
    self.projectId = projectId
  }
}

public struct ServerUpdateBotRequest: Encodable, Equatable, Sendable {
  public var name: String?
  public var symbolName: String?
  public var mascot: ServerBotMascot?
  public var isArchived: Bool?

  public init(
    name: String? = nil, symbolName: String? = nil, mascot: ServerBotMascot? = nil, isArchived: Bool? = nil
  ) {
    self.name = name
    self.symbolName = symbolName
    self.mascot = mascot
    self.isArchived = isArchived
  }
}
