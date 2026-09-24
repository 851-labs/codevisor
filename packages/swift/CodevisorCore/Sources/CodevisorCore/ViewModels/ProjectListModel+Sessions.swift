import Foundation

extension ProjectListModel {
  /// Sessions belonging to a project, newest first. Imported sessions are
  /// hidden unless `showsImportedSessions` is on.
  ///
  /// There is no archive filter here because chats carry no archive state:
  /// the workspace does, and the sidebar composes its rows from workspaces
  /// and their panes. This list answers "does this project have any chat at
  /// all", which is what project visibility turns on.
  public func sessions(in project: Project) -> [ChatSession] {
    sessions
      .filter { session in
        session.projectId == project.id
          && session.serverId == selectedServerId
          && (session.origin == .codevisor || showsImportedSessions)
      }
      .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
  }

  /// True if a project has any visible session (after import gating).
  public func hasVisibleSessions(in project: Project) -> Bool {
    !sessions(in: project).isEmpty
  }
}
