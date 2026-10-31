import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarWorkspaceGroupTests {
  private let studio = Project(id: UUID(), serverId: "studio", name: "codevisor", repoKey: "github.com/acme/codevisor")
  private let linux = Project(id: UUID(), serverId: "linux", name: "api")

  private func item(_ project: Project) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(id: UUID(), serverId: project.serverId, projectId: project.id, routingChatIds: [])
  }

  private func groups(
    _ items: [WorkspaceSidebarItem], _ grouping: SidebarGrouping, pinned: [UUID] = [],
    machineOrder: [String] = [], projectOrder: [String] = []
  )
    -> [SidebarWorkspaceGroup]
  {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinned.map(\.uuidString), projects: [studio, linux],
      defaultServerId: "studio", machineOrder: machineOrder, projectOrder: projectOrder, machineGroup: machineGroup)
  }

  private func machineGroup(_ serverId: String) -> SidebarMachineGroup {
    let key = serverId.hasPrefix("tart-") ? "sandbox-profile:tart" : serverId
    return SidebarMachineGroup(
      key: key, orderKey: "server-\(key)",
      heading: SidebarWorkspaceGroup.Heading(title: key, icon: .system("desktopcomputer")))
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

  @Test("Machines sharing a group share one heading, which names the machine only while it holds just one")
  func sharedMachineGroups() {
    let first = Project(id: UUID(), serverId: "tart-1", name: "codevisor")
    let second = Project(id: UUID(), serverId: "tart-2", name: "codevisor")
    let items = [item(first), item(studio), item(second)]

    let result = groups(items, .machine)
    let alone = groups([item(first), item(studio)], .machine)

    #expect(result.map(\.id) == ["machine:sandbox-profile:tart", "machine:studio"])
    #expect(result[0].items.map(\.id) == [items[0].id, items[2].id])
    #expect(result.map(\.heading?.namesMachine) == [false, true])
    #expect(alone.map(\.heading?.namesMachine) == [true, true])
    #expect(groups(items, .project).allSatisfy { $0.heading?.namesMachine == false })
  }

  @Test("Machines follow the saved order by their server identity, and unknown ones keep their place after it")
  func machinesFollowSavedOrder() {
    let mini = Project(id: UUID(), serverId: "mini", name: "bots")
    let items = [item(linux), item(studio), item(mini)]

    let result = groups(items, .machine, machineOrder: ["server-mini", "server-gone", "server-studio"])

    #expect(result.map(\.heading?.title) == ["mini", "studio", "linux"])
    #expect(groups(items, .project, machineOrder: ["server-studio"]).map(\.id) == groups(items, .project).map(\.id))
  }

  @Test("Projects follow the saved order by repository, or by project id when they have no repository")
  func projectsFollowSavedOrder() {
    let items = [item(studio), item(linux)]
    let natural = groups(items, .project)
    let keys = natural.map(SidebarWorkspaceGroup.projectKey)

    let result = groups(items, .project, projectOrder: ["gone"] + keys.reversed())

    #expect(result.map(\.id) == natural.map(\.id).reversed())
    #expect(keys == ["repo|github.com/acme/codevisor", linux.id.uuidString])
    #expect(groups(items, .machine, projectOrder: keys.reversed()).map(\.id) == groups(items, .machine).map(\.id))
  }

  @Test("Moving a shown group keeps hidden ones where they were saved and adds new ones after them")
  func savedOrderKeepsHiddenGroupsInPlace() {
    #expect(
      SidebarWorkspaceGroup.savedOrder(["a", "b", "c"], moving: "c", to: 0, among: ["a", "c"]) == ["c", "b", "a"])
    #expect(SidebarWorkspaceGroup.savedOrder(["a", "a"], moving: "d", to: 0, among: ["a", "d"]) == ["d", "a"])
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
      SidebarRowSubtitle.make(
        details: details, title: "Fix login", projectName: "api", branch: "main", worktreeName: nil,
        groupNamesProject: false)
        == "api · main")
    #expect(
      SidebarRowSubtitle.make(
        details: details, title: "Fix login", projectName: "api", branch: "main", worktreeName: nil,
        groupNamesProject: true)
        == "main")
    #expect(
      SidebarRowSubtitle.make(
        details: [.machine], title: "Fix login", projectName: "api", branch: "main", worktreeName: nil,
        groupNamesProject: false)
        == nil)
    #expect(
      SidebarRowSubtitle.make(
        details: [.branch, .worktree], title: "Fix login", projectName: "api", branch: "main",
        worktreeName: "emmer", groupNamesProject: false)
        == "main · emmer")
  }

  @Test func subtitleDropsAWorktreeTheTitleAlreadyNames() {
    #expect(
      SidebarRowSubtitle.make(
        details: [.branch, .worktree], title: "emmer", projectName: "api", branch: "codevisor/emmer",
        worktreeName: "emmer", groupNamesProject: false)
        == "codevisor/emmer")
  }

  @MainActor @Test func rowDetailsKeepTheLegacyListUntilEachDetailIsSetOnItsOwn() {
    let preferences = ClientPreferences()
    #expect(preferences.sidebarRowDetails == [.pullRequest, .machine, .project, .branch])
    preferences.set([SidebarRowDetail.project], forKey: SidebarRowDetail.legacyPreferenceKey)
    #expect(preferences.sidebarRowDetails == [.project])
    preferences.setSidebarRowDetail(.project, shown: false)
    preferences.setSidebarRowDetail(.worktree, shown: true)
    #expect(preferences.sidebarRowDetails == [.worktree])
  }
}
