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
  public var harnessId: String
  public var projectId: String
  public var sessionId: String
  public var workspaceId: String
  public var rootPath: String
  public var projects: [ServerBotProject]
  public var conversational: Bool?
  public var createdAt: String
  public var updatedAt: String?

  public init(
    id: String,
    serverId: String,
    name: String,
    symbolName: String,
    harnessId: String,
    projectId: String,
    sessionId: String,
    workspaceId: String,
    rootPath: String,
    projects: [ServerBotProject],
    conversational: Bool? = nil,
    createdAt: String,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.serverId = serverId
    self.name = name
    self.symbolName = symbolName
    self.harnessId = harnessId
    self.projectId = projectId
    self.sessionId = sessionId
    self.workspaceId = workspaceId
    self.rootPath = rootPath
    self.projects = projects
    self.conversational = conversational
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ServerCreateBotRequest: Encodable, Equatable, Sendable {
  public var id: String?
  public var name: String
  public var symbolName: String
  public var harnessId: String
  public var configSelections: [String: String]?
  public var projectIds: [String]
  public var conversational: Bool?

  public init(
    id: String? = nil,
    name: String,
    symbolName: String,
    harnessId: String,
    configSelections: [String: String]? = nil,
    projectIds: [String],
    conversational: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.harnessId = harnessId
    self.configSelections = configSelections
    self.projectIds = projectIds
    self.conversational = conversational
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
  public var conversational: Bool?

  public init(name: String? = nil, symbolName: String? = nil, conversational: Bool? = nil) {
    self.name = name
    self.symbolName = symbolName
    self.conversational = conversational
  }
}
