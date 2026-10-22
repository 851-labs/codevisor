import CodevisorCore
import CodevisorUI

enum SubagentAnnouncementFilter {
  static func install(on environment: AppEnvironment) {
    environment.attentionCoordinator.announcementFilter = { [weak environment] session, openSessions in
      guard let environment else { return true }
      return SubagentAnnouncementRule.shouldAnnounce(
        session,
        workspaceId: environment.navigationStore.projection.sessionIndex[session.sessionId],
        bots: sidebarBots(environment),
        expansion: sidebarExpansion,
        openSessions: openSessions
      )
    }
  }

  private static func sidebarBots(_ environment: AppEnvironment) -> [SidebarRows.Bot]? {
    let preferences = ClientPreferences.shared
    guard preferences.value(forKey: FeatureFlag.bots.preferenceKey, default: false) else { return nil }
    return environment.botSidebarEntries.map(SidebarRows.Bot.init)
  }

  private static var sidebarExpansion: SidebarRows.Expansion {
    let preferences = ClientPreferences.shared
    return SidebarRows.Expansion(
      bots: preferences.value(forKey: SidebarPreferenceKey.botsExpanded, default: true),
      collapsedGroupIDs: Set(
        preferences.value(forKey: SidebarGrouping.collapsedPreferenceKey, default: [String]())
      )
    )
  }
}
