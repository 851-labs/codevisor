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
      defaultServerId: environment.defaultComposerServerId, machineOrder: machineOrder, machineKey: machineKey,
      projectOrder: projectOrder, machineHeading: heading)
  }

  func machineKey(_ serverId: String) -> String {
    environment.navigationStore.machineOrderKey(forMachineId: serverId, machines: environment.machines)
  }

  private var botHomeWorkspaceIDs: Set<UUID> {
    botsEnabled ? Set(environment.bots.bots.map(\.workspaceId)) : []
  }

  private func heading(forServer serverId: String) -> SidebarWorkspaceGroup.Heading {
    let machine = environment.machines.machine(for: serverId)
    return SidebarWorkspaceGroup.Heading(
      title: machine.map(SidebarRowContent.machineName) ?? "Unknown Machine",
      systemImage: machine?.icon.systemImage ?? "questionmark.circle",
      newChatTarget: environment.machines.chatMachine(for: serverId).map { NewChatTarget(machine: $0.id) }
    )
  }
}
