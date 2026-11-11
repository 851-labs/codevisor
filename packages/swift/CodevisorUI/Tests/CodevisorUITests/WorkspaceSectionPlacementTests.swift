import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct WorkspaceSectionPlacementTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")

  private func item(id: UUID = UUID(), parent: UUID? = nil, agentMade: Bool = false) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: id, serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: parent.map { WorkspaceParentLink(workspaceId: $0, linkedAt: .distantPast, isQuiet: agentMade) })
  }

  @Test("Only workspaces shown at the sidebar's top level can move between sections")
  func onlyTopLevelWorkspacesHaveASection() {
    let section = UUID()
    let sectioned = item()
    let unsectioned = item()
    let fork = item(parent: sectioned.id)
    let spawned = item(parent: sectioned.id, agentMade: true)
    let pinnedFork = item(parent: sectioned.id)
    let membership = [sectioned.id: section, pinnedFork.id: section]
    let tree = SidebarWorkspaceTree(
      [sectioned, unsectioned, fork, spawned, pinnedFork], pinnedIDs: [pinnedFork.id.uuidString])

    let placements = [sectioned, unsectioned, fork, spawned, pinnedFork].map {
      WorkspaceSectionPlacement($0.id, in: tree, membership: membership)
    }

    #expect(placements == [.section(section), .unsectioned, nil, nil, .section(section)])
  }
}
