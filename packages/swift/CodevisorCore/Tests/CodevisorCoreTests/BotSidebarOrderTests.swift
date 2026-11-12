import Foundation
import Testing

@testable import CodevisorCore

@Suite("Bot sidebar order")
struct BotSidebarOrderTests {
  @Test("Bots follow their home workspace's sidebar position, whatever their chats did last")
  func followsHomePosition() throws {
    let scout = try conversation("Scout", position: "3000000000008")
    let atlas = try conversation("Atlas", position: "1000000000008")
    let ledger = try conversation("Ledger", position: "2000000000008")

    let sorted = BotSidebarOrder.sorted([scout, atlas, ledger])

    #expect(sorted.map(\.bot.name) == ["Atlas", "Ledger", "Scout"])
  }

  @Test("A bot whose home hasn't synced yet sorts like a new workspace: newest first")
  func unsyncedHomeSortsByCreation() throws {
    let older = try conversation("Older", createdAt: "2026-10-01T00:00:00.000Z")
    let newer = try conversation("Newer", createdAt: "2026-10-02T00:00:00.000Z")

    #expect(BotSidebarOrder.sorted([older, newer]).map(\.bot.name) == ["Newer", "Older"])
  }

  @Test("Archived bots come after active ones, most recently archived first")
  func archivedBotsByArchiveTime() throws {
    let active = try conversation("Active", position: "f000000000008")
    let early = try conversation("Early", position: "1000000000008", archivedAt: "2026-10-03T00:00:00.000Z")
    let late = try conversation("Late", position: "2000000000008", archivedAt: "2026-10-04T00:00:00.000Z")

    #expect(BotSidebarOrder.sorted([early, active, late]).map(\.bot.name) == ["Active", "Late", "Early"])
  }

  @Test("A bot's placement is its section and the bot above it there")
  func currentPlacement() throws {
    let section = UUID()
    let atlas = try conversation("Atlas", position: "1000000000008")
    let scout = try conversation("Scout", position: "2000000000008")
    let ledger = try conversation("Ledger", position: "3000000000008")
    let all = [atlas, scout, ledger]
    let membership = [atlas.id: section, ledger.id: section]

    #expect(
      BotSidebarOrder.placement(of: ledger.id, in: all, membership: membership)
        == BotSidebarPlacement(section: section, after: atlas.id))
    #expect(
      BotSidebarOrder.placement(of: scout.id, in: all, membership: membership)
        == BotSidebarPlacement(section: nil, after: nil))
  }

  @Test("Placing a bot inserts it after the named bot in the target section, or first when none is named")
  func placingAmongSiblings() throws {
    let section = UUID()
    let atlas = try conversation("Atlas", position: "1000000000008")
    let scout = try conversation("Scout", position: "2000000000008")
    let ledger = try conversation("Ledger", position: "3000000000008")
    let all = [atlas, scout, ledger]
    let membership = [atlas.id: section, ledger.id: section]
    func names(_ placement: BotSidebarPlacement) -> [String] {
      BotSidebarOrder.siblings(placing: scout.bot, at: placement, in: all, membership: membership).map(\.name)
    }

    #expect(names(BotSidebarPlacement(section: section, after: atlas.id)) == ["Atlas", "Scout", "Ledger"])
    #expect(names(BotSidebarPlacement(section: section, after: nil)) == ["Scout", "Atlas", "Ledger"])
    #expect(names(BotSidebarPlacement(section: section, after: ledger.id)) == ["Atlas", "Ledger", "Scout"])
    #expect(names(BotSidebarPlacement(section: nil, after: nil)) == ["Scout"])
  }

  private func conversation(
    _ name: String, position: String? = nil, archivedAt: String? = nil,
    createdAt: String = "2026-10-15T00:00:00.000Z"
  ) throws -> BotConversation {
    var record = ServerBot.fixture(name: name)
    record.isArchived = archivedAt != nil
    record.archivedAt = archivedAt
    record.createdAt = createdAt
    let bot = try #require(Bot(serverId: "server-a", record: record))
    let home = position.map { home(of: bot, at: $0) }
    return BotConversation(bot: bot, session: nil, home: home, activity: .idle, isUnread: false)
  }

  private func home(of bot: Bot, at position: String) -> Workspace {
    var workspace = Workspace(
      id: bot.workspaceId, name: bot.name, rootDirectory: nil, serverId: bot.serverId, projectId: bot.projectId,
      centerTree: .leaf(PaneGroupState()), isServerSynced: true, sidebarOrderHead: nil)
    workspace.sidebarPosition = position
    return workspace
  }
}
