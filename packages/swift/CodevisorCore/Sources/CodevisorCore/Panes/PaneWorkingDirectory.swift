import Foundation

public enum PaneWorkingDirectory {
  public enum Anchor: Equatable, Sendable {
    case session(cwd: String?)
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
