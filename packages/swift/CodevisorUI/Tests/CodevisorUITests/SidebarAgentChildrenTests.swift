import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarAgentChildrenTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")

  private func item(
    id: UUID = UUID(), parent: UUID? = nil, agentMade: Bool = false, botId: UUID? = nil
  ) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: id, serverId: project.serverId, projectId: project.id, routingChatIds: [], botId: botId,
      parent: parent.map { WorkspaceParentLink(workspaceId: $0, linkedAt: .distantPast, isAgentMade: agentMade) })
  }

  private func rows(
    _ items: [WorkspaceSidebarItem], archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = 25,
    tabs: [UUID: [UUID]] = [:], selecting selected: UUID? = nil, botHomeIDs: Set<UUID> = []
  ) -> [SidebarRow] {
    let tree = SidebarWorkspaceTree(items, pinnedIDs: [], botHomeIDs: botHomeIDs)
    let groups = SidebarWorkspaceGroup.groups(
      tree.roots, grouping: .flat, pinnedIDs: [], projects: [project], defaultServerId: project.serverId,
      sections: [], membership: [:]
    ) { serverId in
      SidebarMachineGroup(
        key: serverId, orderKey: serverId,
        heading: SidebarWorkspaceGroup.Heading(title: serverId, icon: .system("desktopcomputer")))
    }
    return SidebarRows.derive(
      SidebarRows.State(
        groups: groups, children: tree.children, tabs: tabs, archived: archived,
        archivedVisibleCount: archivedVisibleCount, expansion: SidebarRows.Expansion(archived: true),
        selectedWorkspaceID: selected))
  }

  private func workspaceIDs(_ rows: [SidebarRow]) -> [UUID] {
    rows.compactMap { row in
      guard case let .workspace(item, _) = row.kind else { return nil }
      return item.id
    }
  }

  @Test(
    "Agent-made children never show; forks and legacy children do, and a fork of a hidden child nests under the nearest shown ancestor"
  )
  func agentMadeChildrenAreHidden() {
    let parent = item()
    let fork = item(parent: parent.id)
    let spawned = item(parent: parent.id, agentMade: true)
    let spawnedBySpawned = item(parent: spawned.id, agentMade: true)
    let forkOfSpawned = item(parent: spawnedBySpawned.id)
    let all = [parent, fork, spawned, spawnedBySpawned, forkOfSpawned]

    let shown = rows(all, tabs: [parent.id: [UUID()]], selecting: spawned.id)
    #expect(workspaceIDs(shown) == [parent.id, fork.id, forkOfSpawned.id])
    let forks = shown.filter { [fork.id, forkOfSpawned.id].map(SidebarRowID.workspace).contains($0.id) }
    #expect(forks.map(\.parentID) == [parent.id, parent.id])
    #expect(forks.map(\.depth) == [1, 1])

    let tree = SidebarWorkspaceTree(all, pinnedIDs: [])
    #expect(tree.parent(of: spawnedBySpawned.id) == spawned.id)
    #expect(tree.root(of: forkOfSpawned.id) == parent.id)
  }

  @Test("An agent-made child whose parent isn't listed stays at the top level instead of disappearing")
  func orphanedAgentMadeChildStaysTopLevel() {
    let orphan = item(parent: UUID(), agentMade: true)

    #expect(workspaceIDs(rows([orphan])) == [orphan.id])
  }

  @Test(
    "Agent-made workspaces in a bot's tree never show, while user forks of them and non-bot orphans stay top level"
  )
  func botAgentChildrenAreHidden() {
    let bot = UUID()
    let home = UUID()
    let botChild = item(parent: home, agentMade: true, botId: bot)
    let botGrandchild = item(parent: botChild.id, agentMade: true, botId: bot)
    let homeChildWithoutBotId = item(parent: home, agentMade: true)
    let forkOfHome = item(parent: home, botId: bot)
    let forkOfBotChild = item(parent: botChild.id, botId: bot)
    let orphan = item(parent: UUID(), agentMade: true)
    let all = [botChild, botGrandchild, homeChildWithoutBotId, forkOfHome, forkOfBotChild, orphan]

    let shown = rows(all, botHomeIDs: [home])
    #expect(workspaceIDs(shown) == [forkOfHome.id, forkOfBotChild.id, orphan.id])
    #expect(shown.allSatisfy { $0.parentID == nil })
  }

  @Test("Archived agent-made children don't show in Archived, and don't count toward Show More")
  func archivedAgentMadeChildrenAreHidden() {
    let parent = item()
    let archivedFork = item(parent: parent.id)
    let archivedSpawns = [item(parent: parent.id, agentMade: true), item(parent: parent.id, agentMade: true)]

    let shown = rows([parent], archived: archivedSpawns + [archivedFork], archivedVisibleCount: 1)
    #expect(shown.suffix(2).map(\.id) == [.section(.archived), .workspace(archivedFork.id)])
    #expect(rows([parent], archived: archivedSpawns).contains { $0.id == .section(.archived) } == false)
  }
}
