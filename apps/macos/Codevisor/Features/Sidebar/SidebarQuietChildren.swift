import CodevisorCore
import CodevisorUI

enum SidebarQuietChildren {
  static func current(in environment: AppEnvironment) -> QuietChildren {
    let entries = environment.navigationStore.workspaceEntries
    return QuietChildren(entries.sidebar + entries.archived)
  }

  static func muteAnnouncements(on environment: AppEnvironment) {
    environment.attentionCoordinator.announcementFilter = { [weak environment] session, _ in
      guard let environment else { return true }
      return current(in: environment).announces(
        workspaceId: environment.workspaces.workspaceId(forSession: session.sessionId))
    }
  }
}
