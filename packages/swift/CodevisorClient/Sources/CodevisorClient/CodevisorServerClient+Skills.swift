import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerSkill: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var directoryName: String
  public var description: String?
  public var path: String
  public var invalid: Bool?

  public var id: String { directoryName }

  public init(
    name: String,
    directoryName: String,
    description: String? = nil,
    path: String,
    invalid: Bool? = nil
  ) {
    self.name = name
    self.directoryName = directoryName
    self.description = description
    self.path = path
    self.invalid = invalid
  }
}

public struct ServerSkillsList: Codable, Equatable, Sendable {
  public var dir: String
  public var skills: [ServerSkill]

  public init(dir: String = "", skills: [ServerSkill] = []) {
    self.dir = dir
    self.skills = skills
  }
}

public struct ServerRemoteSkillCandidate: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var directoryName: String
  public var description: String?
  public var alreadyExists: Bool

  public var id: String { directoryName }

  public init(name: String, directoryName: String, description: String? = nil, alreadyExists: Bool = false) {
    self.name = name
    self.directoryName = directoryName
    self.description = description
    self.alreadyExists = alreadyExists
  }
}

public struct ServerComposerSkill: Codable, Equatable, Sendable {
  public var name: String
  public var description: String?
  public var builtin: Bool

  public init(name: String, description: String? = nil, builtin: Bool = false) {
    self.name = name
    self.description = description
    self.builtin = builtin
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
  }
}

struct ServerComposerSkillsList: Decodable {
  var skills: [ServerComposerSkill]
}

extension CodevisorServerClient {
  public func listSkills() async throws -> ServerSkillsList {
    try await get("/v1/skills")
  }

  public func composerSkills(projectId: UUID?, sessionId: UUID?) async throws -> [ServerComposerSkill] {
    let response: ServerComposerSkillsList = try await get(
      Self.composerSkillsPath(projectId: projectId, sessionId: sessionId)
    )
    return response.skills
  }

  static func composerSkillsPath(projectId: UUID?, sessionId: UUID?) throws -> String {
    var components = URLComponents()
    components.path = "/v1/composer-skills"
    let queryItems = [
      projectId.map { URLQueryItem(name: "projectId", value: $0.uuidString) },
      sessionId.map { URLQueryItem(name: "sessionId", value: $0.uuidString) },
    ].compactMap(\.self)
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let path = components.string else { throw CodevisorServerClientError.invalidURL("composer-skills") }
    return path
  }

  private struct SkillContentBody: Codable {
    var content: String
  }

  public func skillContent(directoryName: String) async throws -> String {
    let response: SkillContentBody = try await get("/v1/skills/\(pathComponent(directoryName))")
    return response.content
  }

  public func updateSkill(directoryName: String, content: String) async throws -> ServerSkillsList {
    try await send(
      "/v1/skills/\(pathComponent(directoryName))",
      method: "PUT",
      body: SkillContentBody(content: content)
    )
  }

  private struct CreateSkillBody: Encodable {
    var name: String
    var description: String
    var content: String?
  }

  private struct ImportRemoteSkillBody: Encodable {
    var source: String
    var skillNames: [String]?
  }

  private struct DiscoverRemoteSkillsBody: Encodable {
    var source: String
  }

  private struct DiscoverRemoteSkillsResponse: Decodable {
    var skills: [ServerRemoteSkillCandidate]
  }

  public func createSkill(
    name: String,
    description: String,
    content: String?
  ) async throws -> ServerSkillsList {
    try await send(
      "/v1/skills",
      method: "POST",
      body: CreateSkillBody(name: name, description: description, content: content)
    )
  }

  public func discoverRemoteSkills(source: String) async throws -> [ServerRemoteSkillCandidate] {
    let response: DiscoverRemoteSkillsResponse = try await send(
      "/v1/skills/discover-remote",
      method: "POST",
      body: DiscoverRemoteSkillsBody(source: source)
    )
    return response.skills
  }

  public func importRemoteSkill(source: String, skillNames: [String]?) async throws -> ServerSkillsList {
    try await send(
      "/v1/skills/import-remote",
      method: "POST",
      body: ImportRemoteSkillBody(source: source, skillNames: skillNames)
    )
  }

  public func removeSkill(directoryName: String) async throws -> ServerSkillsList {
    try await send(
      "/v1/skills/\(pathComponent(directoryName))",
      method: "DELETE",
      body: Optional<EmptyBody>.none
    )
  }
}
