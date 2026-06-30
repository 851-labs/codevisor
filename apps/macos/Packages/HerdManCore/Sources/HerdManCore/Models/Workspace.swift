import Foundation

/// A coding workspace (a folder on disk) shown in the sidebar.
public struct Workspace: Identifiable, Sendable, Codable, Equatable {
    /// The SF Symbol used when a workspace has no custom icon.
    public static let defaultSymbolName = "folder"

    public var id: UUID
    public var name: String
    public var folderURL: URL
    public var isArchived: Bool
    /// The SF Symbol shown for this workspace in the sidebar.
    public var symbolName: String
    /// Whether the workspace was added in HerdMan or created while importing
    /// external sessions. Imported workspaces with no visible sessions are hidden.
    public var origin: SessionOrigin
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        folderURL: URL,
        isArchived: Bool = false,
        symbolName: String = Workspace.defaultSymbolName,
        origin: SessionOrigin = .herdman,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.isArchived = isArchived
        self.symbolName = symbolName
        self.origin = origin
        self.createdAt = createdAt
    }

    /// A workspace derived from a folder URL, taking its name from the last path component.
    public static func fromFolder(
        _ url: URL,
        id: UUID = UUID(),
        origin: SessionOrigin = .herdman,
        createdAt: Date = Date()
    ) -> Workspace {
        Workspace(
            id: id,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            folderURL: url,
            origin: origin,
            createdAt: createdAt
        )
    }

    private enum Keys: String, CodingKey {
        case id, name, folderURL, isArchived, symbolName, origin, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        folderURL = try container.decode(URL.self, forKey: .folderURL)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? Workspace.defaultSymbolName
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .herdman
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
