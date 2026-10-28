import CodevisorClient
import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct BotSidebarRowsTests {
  private func conversation(_ name: String) -> BotConversation {
    let record = ServerBot(
      id: UUID().uuidString, serverId: "studio", name: name, symbolName: "sparkles", harnessId: "claude-code",
      projectId: UUID().uuidString, sessionId: UUID().uuidString, workspaceId: UUID().uuidString,
      rootPath: "/bots/\(name)", projects: [], createdAt: "2026-10-27T00:00:00Z")
    return BotConversation(
      bot: Bot(serverId: "studio", record: record)!, session: nil, activity: .idle, isUnread: false)
  }

  @Test("Stepping walks the derived rows: no selection picks the first bot, and the ends don't wrap")
  func steppingWalksDerivedRows() {
    let (atlas, scout, ledger) = (conversation("Atlas"), conversation("Scout"), conversation("Ledger"))
    let rows = BotSidebarRows.derive(BotSidebarRows.State(conversations: [atlas, scout, ledger]))
    func step(from selected: BotConversation?, by offset: Int) -> UUID? {
      BotSidebarRows.step(from: selected?.id, by: offset, in: rows)?.id
    }

    #expect(step(from: nil, by: 1) == atlas.id)
    #expect(step(from: atlas, by: 1) == scout.id)
    #expect(step(from: ledger, by: -1) == scout.id)
    #expect(step(from: ledger, by: 1) == nil)
    #expect(step(from: atlas, by: -1) == nil)
  }
}
