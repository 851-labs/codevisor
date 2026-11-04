import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
struct SidebarChildDisclosureTests {
  private let project = Project(id: UUID(), serverId: "studio", name: "codevisor")
  private let parent = UUID()

  private func child(_ minute: Double, agentMade: Bool) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [],
      parent: WorkspaceParentLink(
        workspaceId: parent, linkedAt: Date(timeIntervalSince1970: minute * 60), isAgentMade: agentMade))
  }

  private func expanded(_ children: [WorkspaceSidebarItem], in preferences: ClientPreferences) -> Bool {
    let root = WorkspaceSidebarItem(id: parent, serverId: project.serverId, projectId: project.id, routingChatIds: [])
    let tree = SidebarWorkspaceTree([root] + children, pinnedIDs: [])
    return SidebarChildDisclosure.current(preferences).isExpanded(parent, in: tree)
  }

  @Test("Until the user chooses, a parent's children start collapsed when its newest child was made by an agent")
  func newestChildDecidesTheDefault() {
    let preferences = ClientPreferences()
    let forked = child(1, agentMade: false)
    let spawned = child(2, agentMade: true)

    #expect(!expanded([spawned], in: preferences))
    #expect(expanded([forked], in: preferences))
    #expect(!expanded([forked, spawned], in: preferences))
    #expect(expanded([spawned, child(3, agentMade: false)], in: preferences))
  }

  @Test("The user's choice wins over the default, even after an agent spawns another child")
  func explicitChoiceWins() {
    let preferences = ClientPreferences()
    let spawned = [child(1, agentMade: true), child(2, agentMade: true)]

    SidebarChildDisclosure.choose(true, for: parent, in: preferences)
    #expect(expanded(spawned, in: preferences))

    SidebarChildDisclosure.choose(false, for: parent, in: preferences)
    #expect(!expanded([child(1, agentMade: false)], in: preferences))

    SidebarChildDisclosure.forget(parent, in: preferences)
    #expect(expanded([child(1, agentMade: false)], in: preferences))
    #expect(preferences.value(forKey: SidebarGrouping.collapsedPreferenceKey, default: ["unset"]) == [])
    #expect(preferences.value(forKey: SidebarChildDisclosure.expandedPreferenceKey, default: ["unset"]) == [])
  }

  @Test("Collapsing by default makes the parent's children quiet, and expanding them makes them speak again")
  func defaultCollapseMakesChildrenQuiet() {
    let preferences = ClientPreferences()
    let spawned = child(1, agentMade: true)
    let root = WorkspaceSidebarItem(id: parent, serverId: project.serverId, projectId: project.id, routingChatIds: [])
    let tree = SidebarWorkspaceTree([root, spawned], pinnedIDs: [])

    #expect(QuietChildren(tree: tree, disclosure: .current(preferences)).contains(spawned.id))

    SidebarChildDisclosure.choose(true, for: parent, in: preferences)
    #expect(!QuietChildren(tree: tree, disclosure: .current(preferences)).contains(spawned.id))
  }
}
