import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarAgentChildrenTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")

  private func item(
    id: UUID = UUID(), parent: UUID? = nil, agentMade: Bool = false, on serverId: String? = nil
  ) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: id, serverId: serverId ?? project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0, linkedAt: .distantPast, isQuiet: agentMade) })
  }

  private func rows(
    _ items: [WorkspaceSidebarItem], archived: [WorkspaceSidebarItem] = [], archivedVisibleCount: Int = 25,
    tabs: [UUID: [UUID]] = [:], selecting selected: UUID? = nil, hiddenParentIDs: Set<UUID> = [],
    pinning pinned: [WorkspaceSidebarItem] = []
  ) -> [SidebarRow] {
    let pinnedIDs = pinned.map(\.id.uuidString)
    let tree = SidebarWorkspaceTree(
      items, pinnedIDs: pinnedIDs, hiddenParentIDs: hiddenParentIDs, revealing: selected)
    let groups = SidebarWorkspaceGroup.groups(
      tree.roots, grouping: .flat, pinnedIDs: pinnedIDs, projects: [project], defaultServerId: project.serverId,
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
    "Agent-made children are hidden; forks and legacy children show, and a fork of a hidden child nests under the nearest shown ancestor"
  )
  func agentMadeChildrenAreHidden() {
    let parent = item()
    let fork = item(parent: parent.id)
    let spawned = item(parent: parent.id, agentMade: true)
    let spawnedBySpawned = item(parent: spawned.id, agentMade: true)
    let forkOfSpawned = item(parent: spawnedBySpawned.id)
    let all = [parent, fork, spawned, spawnedBySpawned, forkOfSpawned]

    let shown = rows(all, tabs: [parent.id: [UUID()]], selecting: parent.id)
    #expect(workspaceIDs(shown) == [parent.id, fork.id, forkOfSpawned.id])
    let forks = shown.filter { [fork.id, forkOfSpawned.id].map(SidebarRowID.workspace).contains($0.id) }
    #expect(forks.map(\.parentID) == [parent.id, parent.id])
    #expect(forks.map(\.depth) == [1, 1])

    let tree = SidebarWorkspaceTree(all, pinnedIDs: [])
    #expect(tree.parent(of: spawnedBySpawned.id) == spawned.id)
    #expect(tree.root(of: forkOfSpawned.id) == parent.id)
  }

  @Test(
    "The selected agent-made child shows as a row nested under its parent, even on another machine, until something else is selected"
  )
  func selectedAgentMadeChildShowsUntilDeselected() {
    let parent = item()
    let local = item(parent: parent.id, agentMade: true)
    let remote = item(parent: parent.id, agentMade: true, on: "mini")
    let unrelated = item()
    let all = [parent, local, remote, unrelated]

    for child in [local, remote] {
      let shown = rows(all, selecting: child.id)
      #expect(workspaceIDs(shown) == [parent.id, child.id, unrelated.id])
      let row = shown.first { $0.id == .workspace(child.id) }
      #expect(row?.parentID == parent.id)
      #expect(row?.depth == 1)
    }
    for selected in [parent.id, unrelated.id, nil] {
      #expect(workspaceIDs(rows(all, selecting: selected)) == [parent.id, unrelated.id])
    }
  }

  @Test(
    "A selected agent-made grandchild nests under the nearest shown ancestor, and its hidden parent stays hidden"
  )
  func selectedAgentMadeGrandchildNestsUnderShownAncestor() {
    let parent = item()
    let spawned = item(parent: parent.id, agentMade: true)
    let spawnedBySpawned = item(parent: spawned.id, agentMade: true)

    let shown = rows([parent, spawned, spawnedBySpawned], selecting: spawnedBySpawned.id)

    #expect(workspaceIDs(shown) == [parent.id, spawnedBySpawned.id])
    #expect(shown.first { $0.id == .workspace(spawnedBySpawned.id) }?.parentID == parent.id)
  }

  @Test("A selected agent-made child of a bot or an archived workspace shows at the top level until deselected")
  func selectedChildOfUnlistedParentShowsTopLevel() {
    let home = UUID()
    let botChild = item(parent: home, agentMade: true)
    let other = item()

    let shown = rows([botChild, other], selecting: botChild.id, hiddenParentIDs: [home])

    #expect(workspaceIDs(shown) == [botChild.id, other.id])
    #expect(shown.allSatisfy { $0.parentID == nil })
    #expect(workspaceIDs(rows([botChild, other], selecting: other.id, hiddenParentIDs: [home])) == [other.id])
  }

  @Test("An agent-made child of an archived workspace stays hidden, even before its own archive arrives")
  func agentMadeChildOfArchivedParentStaysHidden() {
    let archivedParent = UUID()
    let spawned = item(parent: archivedParent, agentMade: true)
    let forked = item(parent: archivedParent)

    let tree = SidebarWorkspaceTree([spawned, forked], pinnedIDs: [], hiddenParentIDs: [archivedParent])

    #expect(tree.roots.map(\.id) == [forked.id])
    #expect(tree.children.isEmpty)
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
    let home = UUID()
    let botChild = item(parent: home, agentMade: true)
    let botGrandchild = item(parent: botChild.id, agentMade: true)
    let forkOfHome = item(parent: home)
    let forkOfBotChild = item(parent: botChild.id)
    let orphan = item(parent: UUID(), agentMade: true)
    let all = [botChild, botGrandchild, forkOfHome, forkOfBotChild, orphan]

    let shown = rows(all, hiddenParentIDs: [home])
    #expect(workspaceIDs(shown) == [forkOfHome.id, forkOfBotChild.id, orphan.id])
    #expect(shown.allSatisfy { $0.parentID == nil })
  }

  @Test("Agent-made workspaces can't be pinned, while top-level workspaces, forks and legacy children can")
  func agentMadeWorkspacesCannotBePinned() {
    let parent = item()
    let fork = item(parent: parent.id)
    let spawned = item(parent: parent.id, agentMade: true)
    let orphan = item(parent: UUID(), agentMade: true)

    #expect([parent, fork, spawned, orphan].map(SidebarPins.canPin) == [true, true, false, false])
  }

  @Test(
    "Stored pins on agent-made workspaces are ignored, so they stay hidden or in the list, while a pinned fork still shows in Pinned"
  )
  func storedAgentMadePinsAreIgnored() {
    let home = UUID()
    let parent = item()
    let fork = item(parent: parent.id)
    let spawned = item(parent: parent.id, agentMade: true)
    let botChild = item(parent: home, agentMade: true)
    let orphan = item(parent: UUID(), agentMade: true)
    let all = [parent, fork, spawned, botChild, orphan]

    let shown = rows(all, hiddenParentIDs: [home], pinning: [fork, spawned, botChild, orphan])
    #expect(
      shown.map(\.id) == [
        .section(.pinned), .workspace(fork.id), .section(.list), .workspace(parent.id), .workspace(orphan.id),
      ])
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
