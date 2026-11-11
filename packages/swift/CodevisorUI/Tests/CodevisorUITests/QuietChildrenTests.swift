import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct QuietChildrenTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")

  private func item(parent: WorkspaceSidebarItem? = nil, agentMade: Bool = false) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0.id, linkedAt: .distantPast, isQuiet: agentMade) })
  }

  @Test("Only agent-made children are quiet; forks, legacy children and top-level workspaces never are")
  func quietMeansAgentMade() {
    let parent = item()
    let spawned = item(parent: parent, agentMade: true)
    let fork = item(parent: parent)
    let forkOfSpawned = item(parent: spawned)
    let spawnedByFork = item(parent: fork, agentMade: true)
    let all = [parent, spawned, fork, forkOfSpawned, spawnedByFork]

    let quiet = QuietChildren(all)

    #expect(all.map { quiet.contains($0.id) } == [false, true, false, false, true])
    #expect(all.map(QuietChildren.isQuiet) == [false, true, false, false, true])
  }

  @Test("An agent-made child's attention is never announced, even with its chat open; everyone else's always is")
  func announcementsSkipAgentMadeChildren() {
    let parent = item()
    let spawned = item(parent: parent, agentMade: true)
    let fork = item(parent: parent)
    let quiet = QuietChildren([parent, spawned, fork])

    #expect(!quiet.announces(workspaceId: spawned.id))
    #expect(quiet.announces(workspaceId: fork.id))
    #expect(quiet.announces(workspaceId: parent.id))
    #expect(quiet.announces(workspaceId: UUID()))
    #expect(quiet.announces(workspaceId: nil))
  }
}
