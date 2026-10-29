import CodevisorCore
import Foundation

@MainActor
public struct SidebarMachineGroups {
  let machines: MachineController
  let navigationStore: NavigationStore
  let machineName: (CodevisorMachine) -> String

  public init(
    machines: MachineController, navigationStore: NavigationStore,
    machineName: @escaping (CodevisorMachine) -> String = \.name
  ) {
    self.machines = machines
    self.navigationStore = navigationStore
    self.machineName = machineName
  }

  public func group(forServer serverId: String) -> SidebarMachineGroup {
    if let profile = machines.sandboxProfile(forMachineId: serverId) { return profileGroup(profile) }
    return machineGroup(serverId)
  }

  private func profileGroup(_ profile: SandboxMachineProfile) -> SidebarMachineGroup {
    let key = "sandbox-profile:\(profile.id)"
    let heading = SidebarWorkspaceGroup.Heading(title: profile.name, icon: .sandboxVendor(profile.vendor))
    return SidebarMachineGroup(key: key, orderKey: key, heading: heading)
  }

  private func machineGroup(_ serverId: String) -> SidebarMachineGroup {
    let machine = machines.machine(for: serverId)
    let heading = SidebarWorkspaceGroup.Heading(
      title: machine.map(machineName) ?? "Unknown Machine",
      icon: .system(machine?.icon.systemImage ?? "questionmark.circle"),
      newChatTarget: machines.chatMachine(for: serverId).map { NewChatTarget(machine: $0.id) }
    )
    let orderKey = navigationStore.machineOrderKey(forMachineId: serverId, machines: machines)
    return SidebarMachineGroup(key: serverId, orderKey: orderKey, heading: heading)
  }
}
