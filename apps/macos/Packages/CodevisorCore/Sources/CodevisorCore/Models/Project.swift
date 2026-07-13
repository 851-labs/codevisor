import Foundation

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

/// A coding project shown in the sidebar. Identity (name, icon) is logical;
/// where it lives on disk is per-machine via `locations`.
public struct Project: Identifiable, Sendable, Codable, Equatable {
    /// The SF Symbol used when a project has no custom icon.
    public static let defaultSymbolName = "folder.fill"

    public var id: UUID
    /// The Codevisor server this cached record was observed on. Legacy/local
    /// projects default to "local".
    public var serverId: String
    public var name: String
    public var isArchived: Bool
    /// The SF Symbol shown for this project in the sidebar.
    public var symbolName: String
    /// Whether the project was added in Codevisor or created while importing
    /// external sessions. Imported projects with no visible sessions are hidden.
    public var origin: SessionOrigin
    public var createdAt: Date
    /// Per-server folders for this project.
    public var locations: [ProjectLocation]

    public init(
        id: UUID = UUID(),
        serverId: String = "local",
        name: String,
        isArchived: Bool = false,
        symbolName: String = Project.defaultSymbolName,
        origin: SessionOrigin = .codevisor,
        createdAt: Date = Date(),
        locations: [ProjectLocation] = []
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.isArchived = isArchived
        self.symbolName = symbolName
        self.origin = origin
        self.createdAt = createdAt
        self.locations = locations
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
        case id, serverId, name, folderURL, isArchived, symbolName, origin, createdAt, locations
    }

    // Custom decoding tolerates records persisted before locations existed
    // (single `folderURL`), synthesizing a location on the record's server.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverId = try container.decodeIfPresent(String.self, forKey: .serverId) ?? "local"
        name = try container.decode(String.self, forKey: .name)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? Project.defaultSymbolName
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .codevisor
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
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
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(origin, forKey: .origin)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(locations, forKey: .locations)
    }
}
