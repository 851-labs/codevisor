import Foundation

/// The remote-tracking branch new Codevisor worktrees start from for one
/// project. The remote is explicit so projects are not tied to `origin`.
public struct ProjectWorktreeBase: Sendable, Codable, Equatable, Hashable {
  public var remote: String
  public var branch: String

  public init(remote: String, branch: String) {
    self.remote = remote
    self.branch = branch
  }

  public var displayName: String { "\(remote)/\(branch)" }
}

/// A folder a project lives in on one machine. A logical project can have a
/// location per server; sessions derive their working directory from the
/// location on the server they run on (or from a worktree).
public struct ProjectLocation: Sendable, Codable, Equatable {
  public var id: String
  public var projectId: UUID
  public var serverId: String
  public var folderPath: String
  /// Whether the folder is a git repository on that machine (server-probed;
  /// nil when unknown). Gates the "new worktree" option in the UI.
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

/// A coding project shown in the sidebar. Its identity is logical; where it
/// lives on disk is per-machine via `locations`.
public struct Project: Identifiable, Sendable, Codable, Equatable {
  public var id: UUID
  /// The Codevisor server this cached record was observed on. Legacy/local
  /// projects default to "local".
  public var serverId: String
  public var name: String
  public var isArchived: Bool
  /// Whether the project was added in Codevisor or created while importing
  /// external sessions. Imported projects with no visible sessions are hidden.
  public var origin: SessionOrigin
  public var createdAt: Date
  /// Per-server folders for this project.
  public var locations: [ProjectLocation]
  /// The git remote configured in the project's folder on its machine, as
  /// the server observed it (nil for non-git folders, folders with no
  /// remote, and records from servers predating remote tracking).
  public var repoUrl: String?
  /// Server-normalized identity of `repoUrl`: equal keys mean the same
  /// repository, whichever machine holds the checkout. This is what groups
  /// one project across machines; a project without one stands alone.
  public var repoKey: String?
  /// Explicit worktree base selected in Manage Project. Nil preserves the
  /// server's legacy origin/main fallback for projects not yet configured.
  public var worktreeBase: ProjectWorktreeBase?
  /// True for the hidden backing project of a scratch workspace — the empty
  /// folder a brand-new chat starts in (under ~/codevisor/workspaces on its
  /// machine). Server-derived from the folder location on every response.
  /// Scratch projects are hidden from project pickers; sessions keep
  /// working through them until the workspace locks a real project in.
  public var isScratch: Bool

  public init(
    id: UUID = UUID(),
    serverId: String = "local",
    name: String,
    isArchived: Bool = false,
    origin: SessionOrigin = .codevisor,
    createdAt: Date = Date(),
    locations: [ProjectLocation] = [],
    repoUrl: String? = nil,
    repoKey: String? = nil,
    worktreeBase: ProjectWorktreeBase? = nil,
    isScratch: Bool = false
  ) {
    self.id = id
    self.serverId = serverId
    self.name = name
    self.isArchived = isArchived
    self.origin = origin
    self.createdAt = createdAt
    self.locations = locations
    self.repoUrl = repoUrl
    self.repoKey = repoKey
    self.worktreeBase = worktreeBase
    self.isScratch = isScratch
  }

  public func location(for serverId: String) -> ProjectLocation? {
    locations.first { $0.serverId == serverId }
  }

  /// The folder on the server this record belongs to (falling back to any
  /// known location so legacy records keep rendering).
  public var folderURL: URL {
    URL(fileURLWithPath: location(for: serverId)?.folderPath ?? locations.first?.folderPath ?? "")
  }

  /// Whether the folder on this record's server is a git repository. False
  /// until the server has probed it.
  public var isGitRepository: Bool {
    location(for: serverId)?.isGitRepository ?? false
  }

  /// A project derived from a folder URL, taking its name from the last path
  /// component and locating it on the given server.
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
    case id, serverId, name, folderURL, isArchived, origin, createdAt, locations
    case isScratch, worktreeBase, repoUrl, repoKey
  }

  // Custom decoding tolerates records persisted before locations existed
  // (single `folderURL`), synthesizing a location on the record's server.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    id = try container.decode(UUID.self, forKey: .id)
    serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
    name = try container.decode(String.self, forKey: .name)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .codevisor
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    isScratch = try container.decodeIfPresent(Bool.self, forKey: .isScratch) ?? false
    repoUrl = try container.decodeIfPresent(String.self, forKey: .repoUrl)
    repoKey = try container.decodeIfPresent(String.self, forKey: .repoKey)
    worktreeBase = try container.decodeIfPresent(ProjectWorktreeBase.self, forKey: .worktreeBase)
    if let locations = try container.decodeIfPresent([ProjectLocation].self, forKey: .locations) {
      self.locations = locations
    } else if let legacyFolderURL = try container.decodeIfPresent(URL.self, forKey: .folderURL) {
      locations = [
        ProjectLocation(projectId: id, serverId: serverId, folderPath: legacyFolderURL.path)
      ]
    } else {
      locations = []
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(id, forKey: .id)
    try container.encode(serverId, forKey: .serverId)
    try container.encode(name, forKey: .name)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encode(origin, forKey: .origin)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(locations, forKey: .locations)
    try container.encodeIfPresent(repoUrl, forKey: .repoUrl)
    try container.encodeIfPresent(repoKey, forKey: .repoKey)
    try container.encodeIfPresent(worktreeBase, forKey: .worktreeBase)
    try container.encode(isScratch, forKey: .isScratch)
  }
}
