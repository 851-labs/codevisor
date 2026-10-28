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

  private func section(_ name: String, at position: String) -> BotSection {
    BotSection(id: UUID(), name: name, position: position)
  }

  @Test(
    "The default list comes first, then each section in order; a bot whose section is gone falls back to the default list"
  )
  func sectionLayout() {
    let (atlas, scout, ledger, patch) = (
      conversation("Atlas"), conversation("Scout"), conversation("Ledger"), conversation("Patch")
    )
    let (work, home) = (section("Work", at: "4000000000008"), section("Home", at: "8000000000008"))
    let state = BotSidebarRows.State(
      conversations: [atlas, scout, ledger, patch], sections: [work, home],
      membership: [scout.id: work.id, ledger.id: UUID(), patch.id: work.id])

    let rows = BotSidebarRows.derive(state)

    #expect(
      rows.map(\.id) == [
        .bot(atlas.id), .bot(ledger.id), .section(work.id), .bot(scout.id), .bot(patch.id), .section(home.id),
      ])
  }

  @Test("A collapsed section keeps only the selected bot, and stepping skips headers and hidden bots")
  func collapsedSectionKeepsSelection() {
    let (atlas, scout, ledger, patch) = (
      conversation("Atlas"), conversation("Scout"), conversation("Ledger"), conversation("Patch")
    )
    let work = section("Work", at: "8000000000008")
    let state = BotSidebarRows.State(
      conversations: [atlas, scout, ledger, patch], sections: [work],
      membership: [scout.id: work.id, ledger.id: work.id, patch.id: work.id], collapsedSectionIDs: [work.id],
      selectedBotID: ledger.id)

    let rows = BotSidebarRows.derive(state)

    #expect(rows.map(\.id) == [.bot(atlas.id), .section(work.id), .bot(ledger.id)])
    #expect(BotSidebarRows.step(from: atlas.id, by: 1, in: rows)?.id == ledger.id)
    #expect(BotSidebarRows.step(from: ledger.id, by: 1, in: rows) == nil)
  }
}
