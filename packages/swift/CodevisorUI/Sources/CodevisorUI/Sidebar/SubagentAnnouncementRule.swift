import CodevisorCore
import Foundation

public enum SubagentAnnouncementRule {
  public static func shouldAnnounce(
    _ session: SessionAttentionFocus,
    workspaceId: UUID?,
    bots: [SidebarRows.Bot]?,
    expansion: SidebarRows.Expansion,
    openSessions: Set<SessionAttentionFocus>
  ) -> Bool {
    guard let bot = owningBot(of: session, workspaceId: workspaceId, bots: bots) else { return true }
    return bot.listsChildren(in: expansion) || openSessions.contains(session)
  }

  private static func owningBot(
    of session: SessionAttentionFocus, workspaceId: UUID?, bots: [SidebarRows.Bot]?
  ) -> SidebarRows.Bot? {
    guard let workspaceId, let bots else { return nil }
    return bots.first { bot in
      bot.workspaceId != workspaceId
        && bot.children.contains { $0.id == workspaceId && $0.serverId == session.serverId }
    }
  }
}
