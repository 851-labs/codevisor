import Foundation

/// Where a pane's work happens. A chat anchors on its own working directory,
/// exactly as it always has; a workspace with no chat anchors on the working
/// directory the workspace itself owns. Neither case silently reinterprets the
/// other's directory as the project root.
public enum PaneWorkingDirectory {
  /// What the pane group is anchored on.
  public enum Anchor: Equatable, Sendable {
    /// A chat mount: the session's cwd (worktree sessions open in the worktree),
    /// else the project folder — unchanged behaviour.
    case session(cwd: String?)
    /// No chat: the workspace's own working directory, else the project folder.
    case workspace
  }

  public static func resolve(
    anchor: Anchor,
    workspaceRootDirectory: String?,
    projectFolderPath: String
  ) -> String {
    switch anchor {
    case let .session(cwd):
      return cwd ?? projectFolderPath
    case .workspace:
      return workspaceRootDirectory ?? projectFolderPath
    }
  }
}
