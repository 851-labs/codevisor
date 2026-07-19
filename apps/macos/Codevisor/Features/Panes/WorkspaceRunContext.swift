//  The places a chat or terminal in a workspace can run: the project root
//  or one of the workspace's chat worktrees. Shared by the composer's run-
//  location picker and the New tab page's directory picker so both surfaces
//  present the same choices the same way — by NAME (project or worktree),
//  never as a generic "workspace directory".

import Foundation
import CodevisorCore

/// One selectable run location. Identity is the worktree name (or "the
/// project root"), not the path — two chats sharing a worktree are one entry.
struct WorkspaceRunContext: Identifiable, Equatable {
    enum Kind: Equatable {
        case projectRoot
        case worktree
    }

    let kind: Kind
    /// Display name: the PROJECT name for the root, the worktree name
    /// otherwise. Chips and menu rows show this, never the path.
    let name: String
    /// Absolute path the pane runs in (~-abbreviate only at display time).
    let path: String
    /// Rides onto created sessions; nil for the project root.
    let worktreeName: String?

    var id: String { worktreeName.map { "worktree-\($0)" } ?? "project-root" }

    /// The `~`-abbreviated path for menu-row subtitles.
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// The menu/chip icon: a folder for the root, a branch for worktrees.
    var symbolName: String {
        switch kind {
        case .projectRoot: "folder.fill"
        case .worktree: "arrow.triangle.branch"
        }
    }
}

@MainActor
enum WorkspaceRunContexts {
    /// The workspace's run locations: the project root first, then each
    /// unarchived chat's worktree (deduped by name; archived chats'
    /// worktrees aren't part of the working set, and a worktree that IS
    /// the root — legacy workspaces born from the old form's toggle —
    /// isn't repeated). Worktrees still materializing (nil cwd) are
    /// excluded; they appear once the server resolves their path.
    ///
    /// `sessions` must already be scoped to the workspace's server.
    static func contexts(
        workspace: Workspace,
        project: Project,
        sessions: [ChatSession]
    ) -> [WorkspaceRunContext] {
        var options: [WorkspaceRunContext] = [
            WorkspaceRunContext(
                kind: .projectRoot,
                name: project.name,
                path: workspace.rootDirectory ?? project.folderURL.path,
                worktreeName: nil
            )
        ]
        var seen: Set<String> = []
        for chatId in workspace.chatSessionIds {
            guard let chat = sessions.first(where: { $0.id == chatId }),
                  !chat.isArchived,
                  let worktreeName = chat.worktreeName,
                  let cwd = chat.cwd,
                  cwd != workspace.rootDirectory,
                  seen.insert(worktreeName).inserted else { continue }
            options.append(WorkspaceRunContext(
                kind: .worktree,
                name: worktreeName,
                path: cwd,
                worktreeName: worktreeName
            ))
        }
        return options
    }
}
