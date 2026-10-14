import Foundation

public struct ProjectWorktreeBase: Sendable, Codable, Equatable, Hashable {
  public var remote: String
  public var branch: String

  public init(remote: String, branch: String) {
    self.remote = remote
    self.branch = branch
  }

  public var displayName: String { "\(remote)/\(branch)" }
}

public enum ProjectRunLocation: String, Sendable, Codable, Equatable, Hashable {
  case projectDirectory
  case newWorktree

  public init(newWorktree: Bool) {
    self = newWorktree ? .newWorktree : .projectDirectory
  }

  public var isNewWorktree: Bool { self == .newWorktree }
}

public struct ProjectLocation: Sendable, Codable, Equatable {
  public var id: String
  public var projectId: UUID
  public var serverId: String
  public var folderPath: String
  public var isGitRepository: Bool?

  public init(
    id: String = UUID().uuidString,
    projectId: UUID,
    serverId: String,
    folderPath: String,
    isGitRepository: Bool? = nil
  ) {
    self.id = id
    self.projectId = projectId
    self.serverId = serverId
    self.folderPath = folderPath
    self.isGitRepository = isGitRepository
  }

  public var folderURL: URL {
    URL(fileURLWithPath: folderPath)
  }
}

public struct Project: Identifiable, Sendable, Codable, Equatable {
  public var id: UUID
  public var serverId: String
  public var name: String
  public var origin: SessionOrigin
  public var createdAt: Date
  public var locations: [ProjectLocation]
  public var repoUrl: String?
  public var repoKey: String?
  public var worktreeBase: ProjectWorktreeBase?
  public var defaultRunLocation: ProjectRunLocation?
  public var isScratch: Bool

  public init(
    id: UUID = UUID(),
    serverId: String = "local",
    name: String,
    origin: SessionOrigin = .codevisor,
    createdAt: Date = Date(),
    locations: [ProjectLocation] = [],
    repoUrl: String? = nil,
    repoKey: String? = nil,
    worktreeBase: ProjectWorktreeBase? = nil,
    defaultRunLocation: ProjectRunLocation? = nil,
    isScratch: Bool = false
  ) {
    self.id = id
    self.serverId = serverId
    self.name = name
    self.origin = origin
    self.createdAt = createdAt
    self.locations = locations
    self.repoUrl = repoUrl
    self.repoKey = repoKey
    self.worktreeBase = worktreeBase
    self.defaultRunLocation = defaultRunLocation
    self.isScratch = isScratch
  }

  public func location(for serverId: String) -> ProjectLocation? {
    locations.first { $0.serverId == serverId }
  }

  public var folderURL: URL {
    URL(fileURLWithPath: location(for: serverId)?.folderPath ?? locations.first?.folderPath ?? "")
  }

  public var isGitRepository: Bool {
    location(for: serverId)?.isGitRepository ?? false
  }

  public static func fromFolder(
    _ url: URL,
    id: UUID = UUID(),
    serverId: String = "local",
    origin: SessionOrigin = .codevisor,
    createdAt: Date = Date()
  ) -> Project {
    Project(
      id: id,
      serverId: serverId,
      name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
      origin: origin,
      createdAt: createdAt,
      locations: [
        ProjectLocation(projectId: id, serverId: serverId, folderPath: url.path)
      ]
    )
  }

  private enum Keys: String, CodingKey {
    case id, serverId, name, folderURL, origin, createdAt, locations
    case isScratch, worktreeBase, defaultRunLocation, repoUrl, repoKey
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    id = try container.decode(UUID.self, forKey: .id)
    serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
    name = try container.decode(String.self, forKey: .name)
    origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .codevisor
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    isScratch = try container.decodeIfPresent(Bool.self, forKey: .isScratch) ?? false
    repoUrl = try container.decodeIfPresent(String.self, forKey: .repoUrl)
    repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
    worktreeBase = try container.decodeIfPresent(ProjectWorktreeBase.self, forKey: .worktreeBase)
    defaultRunLocation = try container.decodeIfPresent(String.self, forKey: .defaultRunLocation)
      .flatMap(ProjectRunLocation.init(rawValue:))
    locations = try Self.decodeLocations(from: container, projectId: id, serverId: serverId)
  }

  private static func decodeLocations(
    from container: KeyedDecodingContainer<Keys>, projectId: UUID, serverId: String
  ) throws -> [ProjectLocation] {
    if let locations = try container.decodeIfPresent([ProjectLocation].self, forKey: .locations) {
      return locations
    } else if let legacyFolderURL = try container.decodeIfPresent(URL.self, forKey: .folderURL) {
      return [
        ProjectLocation(projectId: projectId, serverId: serverId, folderPath: legacyFolderURL.path)
      ]
    } else {
      return []
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(id, forKey: .id)
    try container.encode(serverId, forKey: .serverId)
    try container.encode(name, forKey: .name)
    try container.encode(origin, forKey: .origin)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(locations, forKey: .locations)
    try container.encodeIfPresent(repoUrl, forKey: .repoUrl)
    try container.encodeIfPresent(repoKey, forKey: .repoKey)
    try container.encodeIfPresent(worktreeBase, forKey: .worktreeBase)
    try container.encodeIfPresent(defaultRunLocation, forKey: .defaultRunLocation)
    try container.encode(isScratch, forKey: .isScratch)
  }
}
