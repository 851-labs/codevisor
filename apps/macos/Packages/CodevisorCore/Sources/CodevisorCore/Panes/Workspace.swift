//  A workspace: the persistence root for everything in a window's content
//  area. It owns the center split tree (whose leaves are tabbed pane groups —
//  chats, terminals, and later diff viewers/previews) and the ⌘J bottom
//  panel. Chats are REFERENCES to sessions (the server owns transcripts and
//  lifecycle); a workspace can host many, each anchored to a directory under
//  the workspace's root.

import Foundation

public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Display name. While `hasCustomName` is false it tracks the primary
    /// chat's session title; an explicit rename pins it.
    public var name: String
    public var hasCustomName: Bool
    /// The workspace's anchor directory (project checkout or worktree). Every
    /// chat/terminal in the workspace runs at or under this root. Nil when
    /// the backing session hasn't resolved its directory yet.
    public var rootDirectory: String?
    /// The workspace's SF Symbol, seeded from its project's icon at
    /// creation; the user can change it later. Nil (pre-icon workspaces)
    /// falls back to the project's icon in the UI.
    public var symbolName: String?
    /// The machine the workspace's sessions and shells live on.
    public let serverId: String
    public let projectId: UUID
    /// The center area's layout: a tree of splits over tabbed groups.
    public var centerTree: SplitNode
    /// The ⌘J bottom panel.
    public var bottomGroup: PaneGroupState
    public var createdAt: Date
    /// Archived workspaces leave the sidebar (their chats archive with
    /// them) but keep their layout — opening an archived chat revives the
    /// workspace intact. Decoded leniently: payloads written before this
    /// field existed load as not archived.
    public var isArchived: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, hasCustomName, rootDirectory, symbolName, serverId
        case projectId, centerTree, bottomGroup, createdAt, isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hasCustomName = try container.decode(Bool.self, forKey: .hasCustomName)
        rootDirectory = try container.decodeIfPresent(String.self, forKey: .rootDirectory)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)
        serverId = try container.decode(String.self, forKey: .serverId)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        centerTree = try container.decode(SplitNode.self, forKey: .centerTree)
        bottomGroup = try container.decode(PaneGroupState.self, forKey: .bottomGroup)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hasCustomName: Bool = false,
        rootDirectory: String?,
        symbolName: String? = nil,
        serverId: String,
        projectId: UUID,
        centerTree: SplitNode,
        bottomGroup: PaneGroupState,
        createdAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hasCustomName = hasCustomName
        self.rootDirectory = rootDirectory
        self.symbolName = symbolName
        self.serverId = serverId
        self.projectId = projectId
        self.centerTree = centerTree
        self.bottomGroup = bottomGroup
        self.createdAt = createdAt
        self.isArchived = isArchived
    }

    /// Session ids of every chat pane in the workspace, reading order.
    public var chatSessionIds: [UUID] {
        centerTree.allGroups.flatMap { group in
            group.state.panes.compactMap { $0.kind == .chat ? $0.chatSessionId : nil }
        }
    }
}
