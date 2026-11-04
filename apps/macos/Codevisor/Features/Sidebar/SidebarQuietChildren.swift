import CodevisorCore
import CodevisorUI

enum SidebarQuietChildren {
  static func current(in environment: AppEnvironment, preferences: ClientPreferences = .shared) -> QuietChildren {
    let listing = SidebarWorkspaceListing(
      environment: environment,
      botsEnabled: preferences.value(forKey: FeatureFlag.bots.preferenceKey, default: false),
      grouping: .flat,
      pinnedIDs: preferences.value(forKey: SidebarPreferenceKey.pinnedWorkspaces, default: [String]()),
      machineOrder: [], projectOrder: [])
    return QuietChildren(tree: listing.tree, disclosure: .current(preferences))
  }

  static func muteAnnouncements(on environment: AppEnvironment) {
    environment.attentionCoordinator.announcementFilter = { [weak environment] session, openSessions in
      guard let environment else { return true }
      return current(in: environment).announces(
        session, workspaceId: environment.workspaces.workspaceId(forSession: session.sessionId),
        openSessions: openSessions)
    }
  }
}
