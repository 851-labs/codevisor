import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SubagentAnnouncementRuleTests {
  enum Placement: Sendable {
    case botHome
    case botSubagent
    case plainWorkspace
  }

  enum Sidebar: Sendable {
    case expanded
    case botCollapsed
    case botsSectionCollapsed
    case botsDisabled
  }

  enum Openness: Sendable {
    case closed
    case open
    case otherSessionOpen
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let placement: Placement
    let sidebar: Sidebar
    let openness: Openness
    let announces: Bool

    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "top-level bot, collapsed", placement: .botHome, sidebar: .botCollapsed, openness: .closed, announces: true),
    Case(name: "sub-agent, expanded", placement: .botSubagent, sidebar: .expanded, openness: .closed, announces: true),
    Case(
      name: "sub-agent, collapsed", placement: .botSubagent, sidebar: .botCollapsed, openness: .closed, announces: false
    ),
    Case(
      name: "sub-agent, collapsed but open", placement: .botSubagent, sidebar: .botCollapsed, openness: .open,
      announces: true),
    Case(
      name: "sub-agent, collapsed, another chat open", placement: .botSubagent, sidebar: .botCollapsed,
      openness: .otherSessionOpen, announces: false),
    Case(
      name: "sub-agent, Bots section collapsed", placement: .botSubagent, sidebar: .botsSectionCollapsed,
      openness: .closed, announces: false),
    Case(
      name: "sub-agent, bots disabled", placement: .botSubagent, sidebar: .botsDisabled, openness: .closed,
      announces: true),
    Case(
      name: "plain workspace, collapsed", placement: .plainWorkspace, sidebar: .botCollapsed, openness: .closed,
      announces: true),
  ]

  @Test("Only a closed sub-agent of a collapsed bot stays quiet", arguments: cases)
  func decision(_ testCase: Case) {
    let session = SessionAttentionFocus(serverId: "studio", sessionId: UUID())
    let home = UUID()
    let subagent = WorkspaceSidebarItem(
      id: UUID(), serverId: "studio", projectId: UUID(), routingChatIds: [session.sessionId], botId: UUID())
    let bot = SidebarRows.Bot(id: UUID(), serverId: "studio", workspaceId: home, children: [subagent])

    let announces = SubagentAnnouncementRule.shouldAnnounce(
      session,
      workspaceId: workspaceId(testCase.placement, home: home, subagent: subagent.id),
      bots: testCase.sidebar == .botsDisabled ? nil : [bot],
      expansion: expansion(testCase.sidebar, bot: bot),
      openSessions: openSessions(testCase.openness, session: session)
    )

    #expect(announces == testCase.announces)
  }

  @Test("A sub-agent on another machine with the same workspace id is not muted")
  func otherMachine() {
    let session = SessionAttentionFocus(serverId: "linux", sessionId: UUID())
    let subagent = WorkspaceSidebarItem(id: UUID(), serverId: "studio", projectId: UUID(), routingChatIds: [])
    let bot = SidebarRows.Bot(id: UUID(), serverId: "studio", workspaceId: UUID(), children: [subagent])

    let announces = SubagentAnnouncementRule.shouldAnnounce(
      session, workspaceId: subagent.id, bots: [bot],
      expansion: SidebarRows.Expansion(collapsedGroupIDs: [bot.groupID]), openSessions: [])

    #expect(announces)
  }

  private func workspaceId(_ placement: Placement, home: UUID, subagent: UUID) -> UUID? {
    switch placement {
    case .botHome: home
    case .botSubagent: subagent
    case .plainWorkspace: UUID()
    }
  }

  private func expansion(_ sidebar: Sidebar, bot: SidebarRows.Bot) -> SidebarRows.Expansion {
    switch sidebar {
    case .expanded, .botsDisabled: SidebarRows.Expansion()
    case .botCollapsed: SidebarRows.Expansion(collapsedGroupIDs: [bot.groupID])
    case .botsSectionCollapsed: SidebarRows.Expansion(bots: false)
    }
  }

  private func openSessions(_ openness: Openness, session: SessionAttentionFocus) -> Set<SessionAttentionFocus> {
    switch openness {
    case .closed: []
    case .open: [session]
    case .otherSessionOpen: [SessionAttentionFocus(serverId: session.serverId, sessionId: UUID())]
    }
  }
}
