import CodevisorCore
import CodevisorUI
import Foundation

@MainActor
struct SidebarWorkspaceListing {
  let environment: AppEnvironment
  let botsEnabled: Bool
  let grouping: SidebarGrouping
  let pinnedIDs: [String]
  let machineOrder: [String]
  let projectOrder: [String]

  var listedItems: [WorkspaceSidebarItem] {
    let botHomes = botHomeWorkspaceIDs
    return environment.navigationStore.workspaceEntries.sidebar.filter {
      environment.machines.machine(for: $0.serverId) != nil && !botHomes.contains($0.id)
    }
  }

  var groups: [SidebarWorkspaceGroup] {
    groups(of: listedItems)
  }

  var tree: SidebarWorkspaceTree {
    SidebarWorkspaceTree(listedItems, pinnedIDs: pinnedIDs)
  }

  func groups(of items: [WorkspaceSidebarItem]) -> [SidebarWorkspaceGroup] {
    SidebarWorkspaceGroup.groups(
      items, grouping: grouping, pinnedIDs: pinnedIDs, projects: environment.projectList.projects,
      defaultServerId: environment.defaultComposerServerId, machineOrder: machineOrder,
      projectOrder: projectOrder, machineGroup: machineGroups.group(forServer:))
  }

  func headingNamesMachine(_ id: UUID) -> Bool {
    let tree = tree
    let root = tree.root(of: id)
    let group = groups(of: tree.roots).first { $0.items.contains { $0.id == root } }
    return group?.heading?.namesMachine == true
  }

  var machineGroups: SidebarMachineGroups {
    SidebarMachineGroups(
      machines: environment.machines, navigationStore: environment.navigationStore,
      machineName: SidebarRowContent.machineName)
  }

  private var botHomeWorkspaceIDs: Set<UUID> {
    botsEnabled ? Set(environment.bots.bots.map(\.workspaceId)) : []
  }
}
