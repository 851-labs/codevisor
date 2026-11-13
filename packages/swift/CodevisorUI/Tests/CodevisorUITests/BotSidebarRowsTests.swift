import CodevisorClient
import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct BotSidebarRowsTests {
  private func conversation(_ name: String, isArchived: Bool = false) -> BotConversation {
    let record = ServerBot(
      id: UUID().uuidString, serverId: "studio", name: name, symbolName: "sparkles", harnessId: "claude-code",
      projectId: UUID().uuidString, sessionId: UUID().uuidString, workspaceId: UUID().uuidString,
      rootPath: "/bots/\(name)", projects: [], isArchived: isArchived, createdAt: "2026-10-27T00:00:00Z")
    return BotConversation(
      bot: Bot(serverId: "studio", record: record)!, session: nil, home: nil, activity: .idle, isUnread: false)
  }

  @Test("Stepping walks the derived rows: no selection enters at the end it moves from, and the ends don't wrap")
  func steppingWalksDerivedRows() {
    let (atlas, scout, ledger) = (conversation("Atlas"), conversation("Scout"), conversation("Ledger"))
    let rows = BotSidebarRows.derive(BotSidebarRows.State(conversations: [atlas, scout, ledger]))
    func step(from selected: BotConversation?, by offset: Int) -> UUID? {
      BotSidebarRows.step(from: selected?.id, by: offset, in: rows)?.id
    }

    #expect(step(from: nil, by: 1) == atlas.id)
    #expect(step(from: nil, by: -1) == ledger.id)
    #expect(step(from: atlas, by: 1) == scout.id)
    #expect(step(from: ledger, by: -1) == scout.id)
    #expect(step(from: ledger, by: 1) == nil)
    #expect(step(from: atlas, by: -1) == nil)
  }

  private func section(_ name: String, at position: String) -> CustomSection {
    CustomSection(id: UUID(), name: name, position: position)
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

  @Test(
    "Archived bots leave their sections for a trailing Archived section that shows only the selected bot while collapsed"
  )
  func archivedSection() {
    let (atlas, scout, ledger, patch) = (
      conversation("Atlas"), conversation("Scout", isArchived: true), conversation("Ledger"),
      conversation("Patch", isArchived: true)
    )
    let work = section("Work", at: "8000000000008")
    var state = BotSidebarRows.State(
      conversations: [atlas, scout, ledger, patch], sections: [work],
      membership: [scout.id: work.id, ledger.id: work.id], selectedBotID: patch.id)

    let collapsed = BotSidebarRows.derive(state)
    state.isArchivedExpanded = true
    let expanded = BotSidebarRows.derive(state)
    state.conversations = [atlas, ledger]
    let withoutArchived = BotSidebarRows.derive(state)

    #expect(
      collapsed.map(\.id) == [.bot(atlas.id), .section(work.id), .bot(ledger.id), .archivedSection, .bot(patch.id)])
    #expect(
      expanded.map(\.id) == [
        .bot(atlas.id), .section(work.id), .bot(ledger.id), .archivedSection, .bot(scout.id), .bot(patch.id),
      ])
    #expect(BotSidebarRows.step(from: ledger.id, by: 1, in: expanded)?.id == scout.id)
    #expect(withoutArchived.map(\.id) == [.bot(atlas.id), .section(work.id), .bot(ledger.id)])
  }

  @Test("With no active bots, section headers drop out: only Archived shows, or nothing when there are no bots")
  func noActiveBotsLeavesNoEmptyHeaders() {
    let scout = conversation("Scout", isArchived: true)
    let work = section("Work", at: "8000000000008")
    var state = BotSidebarRows.State(conversations: [scout], sections: [work], membership: [scout.id: work.id])

    let archivedOnly = BotSidebarRows.derive(state)
    state.conversations = []
    let noBots = BotSidebarRows.derive(state)

    #expect(archivedOnly.map(\.id) == [.archivedSection])
    #expect(noBots.isEmpty)
  }

  @Test("Archiving the selected bot hands the selection to the next active bot, or the previous one at the end")
  func archiveReplacement() {
    let (atlas, scout, ledger) = (
      conversation("Atlas"), conversation("Scout"), conversation("Ledger", isArchived: true)
    )
    let rows = BotSidebarRows.derive(
      BotSidebarRows.State(conversations: [atlas, scout, ledger], isArchivedExpanded: true))

    #expect(BotSidebarRows.replacement(forArchiving: atlas.id, in: rows)?.id == scout.id)
    #expect(BotSidebarRows.replacement(forArchiving: scout.id, in: rows)?.id == atlas.id)
    #expect(BotSidebarRows.replacement(forArchiving: ledger.id, in: rows) == nil)
    #expect(BotSidebarRows.replacement(forArchiving: atlas.id, in: Array(rows.prefix(1))) == nil)
  }

  @Test(
    "A drop line names its section and the bot above it: the top of the list, right under a header, or under any bot"
  )
  func dropPlacement() {
    let (atlas, scout, ledger, patch) = (
      conversation("Atlas"), conversation("Scout"), conversation("Ledger"), conversation("Patch", isArchived: true)
    )
    let (work, home) = (section("Work", at: "4000000000008"), section("Home", at: "8000000000008"))
    let rows = BotSidebarRows.derive(
      BotSidebarRows.State(
        conversations: [atlas, scout, ledger, patch], sections: [work, home],
        membership: [scout.id: work.id, ledger.id: work.id], isArchivedExpanded: true))
    func placement(_ index: Int) -> BotSidebarPlacement {
      BotSidebarRows.placement(insertingAt: index, excluding: scout.id, in: rows)
    }

    #expect(
      BotSidebarRows.dropSlots(in: rows) == [
        .bot(atlas.id), .section(work.id), .bot(scout.id), .bot(ledger.id), .section(home.id),
      ])
    #expect(placement(0) == BotSidebarPlacement(section: nil, after: nil))
    #expect(placement(1) == BotSidebarPlacement(section: nil, after: atlas.id))
    #expect(placement(2) == BotSidebarPlacement(section: work.id, after: nil))
    #expect(placement(3) == BotSidebarPlacement(section: work.id, after: ledger.id))
    #expect(placement(4) == BotSidebarPlacement(section: home.id, after: nil))
  }

  @Test("A list move (destination counted before removal) lands after the bot that ends up above it")
  func listMovePlacement() {
    let (atlas, scout, ledger) = (UUID(), UUID(), UUID())
    let section = UUID()
    func placement(_ index: Int, to destination: Int) -> BotSidebarPlacement {
      BotSidebarRows.placement(moving: index, to: destination, among: [atlas, scout, ledger], section: section)
    }

    #expect(placement(2, to: 0) == BotSidebarPlacement(section: section, after: nil))
    #expect(placement(2, to: 1) == BotSidebarPlacement(section: section, after: atlas))
    #expect(placement(0, to: 3) == BotSidebarPlacement(section: section, after: ledger))
    #expect(placement(0, to: 2) == BotSidebarPlacement(section: section, after: scout))
  }
}
