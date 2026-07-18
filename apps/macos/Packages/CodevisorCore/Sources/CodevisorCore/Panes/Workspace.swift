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
    /// The machine the workspace's sessions and shells live on.
    public let serverId: String
    public let projectId: UUID
    /// The center area's layout: a tree of splits over tabbed groups.
    public var centerTree: SplitNode
    /// The ⌘J bottom panel.
    public var bottomGroup: PaneGroupState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        hasCustomName: Bool = false,
        rootDirectory: String?,
        serverId: String,
        projectId: UUID,
        centerTree: SplitNode,
        bottomGroup: PaneGroupState,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hasCustomName = hasCustomName
        self.rootDirectory = rootDirectory
        self.serverId = serverId
        self.projectId = projectId
        self.centerTree = centerTree
        self.bottomGroup = bottomGroup
        self.createdAt = createdAt
    }

    /// Session ids of every chat pane in the workspace, reading order.
    public var chatSessionIds: [UUID] {
        centerTree.allGroups.flatMap { group in
            group.state.panes.compactMap { $0.kind == .chat ? $0.chatSessionId : nil }
        }
    }
}
