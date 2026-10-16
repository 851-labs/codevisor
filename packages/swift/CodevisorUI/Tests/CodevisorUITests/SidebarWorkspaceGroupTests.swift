import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarWorkspaceGroupTests {
  private let studio = Project(id: UUID(), serverId: "studio", name: "codevisor")
  private let linux = Project(id: UUID(), serverId: "linux", name: "api")

  private func item(_ project: Project) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [])
  }

  private func groups(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping, pinned: [UUID] = [],
    machineOrder: [String] = []
  )
    -> [SidebarWorkspaceGroup]
  {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux],
      defaultServerId: "studio", machineOrder: machineOrder, machineKey: { "server-\($0)" }
    ) { serverId in SidebarWorkspaceGroup.Heading(title: serverId, systemImage: "desktopcomputer") }
  }

  @Test func pinnedWorkspacesLeaveTheirGroupAndLeadTheList() {
    let first = item(studio)
    let second = item(linux)
    let third = item(studio)
    let result = groups([first, second, third], .project, pinned: [second.id])
    #expect(result.map(\.id).first == SidebarWorkspaceGroup.pinnedID)
    #expect(result[0].items.map(\.id) == [second.id])
    #expect(result.dropFirst().map { $0.items.map(\.id) } == [[first.id, third.id]])
    #expect(result.dropFirst().map(\.heading?.title) == ["codevisor"])
  }

  @Test func groupsKeepFirstAppearanceOrder() {
    let items = [item(linux), item(studio), item(linux)]
    let result = groups(items, .machine)
    #expect(result.map(\.heading?.title) == ["linux", "studio"])
    #expect(result[0].items.map(\.id) == [items[0].id, items[2].id])
  }

  @Test("Machines follow the saved order by their server identity, and unknown ones keep their place after it")
  func machinesFollowSavedOrder() {
    let mini = Project(id: UUID(), serverId: "mini", name: "bots")
    let items = [item(linux), item(studio), item(mini)]

    let result = groups(items, .machine, machineOrder: ["server-mini", "server-gone", "server-studio"])

    #expect(result.map(\.heading?.title) == ["mini", "studio", "linux"])
    #expect(groups(items, .project, machineOrder: ["server-studio"]).map(\.id) == groups(items, .project).map(\.id))
  }

  @Test func flatGroupingHasNoHeadingAndNoPinnedGroupWithoutPins() {
    let items = [item(studio), item(linux)]
    let result = groups(items, .flat)
    #expect(result.count == 1)
    #expect(result[0].heading == nil)
    #expect(result[0].items.map(\.id) == items.map(\.id))
  }

  @Test func subtitleDropsTheProjectAGroupHeadingAlreadyNames() {
    let details = SidebarRowDetail.defaults
    #expect(
      SidebarRowSubtitle.make(details: details, projectName: "api", branch: "main", groupNamesProject: false)
        == "api · main")
    #expect(
      SidebarRowSubtitle.make(details: details, projectName: "api", branch: "main", groupNamesProject: true)
        == "main")
    #expect(
      SidebarRowSubtitle.make(details: [.machine], projectName: "api", branch: "main", groupNamesProject: false)
        == nil)
  }
}
