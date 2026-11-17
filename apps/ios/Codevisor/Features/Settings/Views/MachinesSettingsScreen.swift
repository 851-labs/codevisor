import CodevisorCore
import CodevisorUI
import SwiftUI

struct MachinesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var editingMachine: CloudMachine?
  @State private var removingCloudMachine: CloudMachine?
  @State private var trustingKey: CloudMachine?

  let focusedMachineID: String?

  private var machines: MachineController { environment.machines }
  private var cloud: CloudAccountController { environment.cloud }

  init(focusedMachineID: String? = nil) {
    self.focusedMachineID = focusedMachineID
  }

  private var accountMachines: [CodevisorMachine] {
    machines.allMachines.filter { !$0.isLocal }
  }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        Section {
          ForEach(accountMachines, id: \.id) { machine in
            machineRow(machine)
              .id(machine.id)
          }
          if let lastError = cloud.lastError {
            Text(lastError)
              .foregroundStyle(.red)
          }
        } footer: {
          InlineCodeText(
            "To add a machine, install Codevisor on it and run `codevisor auth login` to sign in to this account."
          )
        }

        Section {
          ConnectOverLANRow()
        } footer: {
          Text("Connect to your machines directly over the local network when available.")
        }
      }
      .task(id: focusedMachineID) {
        guard let focusedMachineID else { return }
        await Task.yield()
        withAnimation(.snappy(duration: 0.3)) {
          proxy.scrollTo(focusedMachineID, anchor: .center)
        }
      }
    }
    .navigationTitle("Machines")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editingMachine) { machine in
      EditMachineSheet(machine: machine, icon: machines.icon(for: machine)) { name, icon in
        Task { await cloud.updateMachine(deviceId: machine.deviceId, name: name, icon: icon) }
      }
    }
    .task {
      while !Task.isCancelled {
        await cloud.refreshMachines()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  private func cloudMachine(for machine: CodevisorMachine) -> CloudMachine? {
    machines.cloudMachine(forMachineId: machine.id)
  }

  private func removeMachine(_ machine: CodevisorMachine) {
    removingCloudMachine = cloudMachine(for: machine)
  }

  private func machineRow(_ machine: CodevisorMachine) -> some View {
    let presence = cloudMachine(for: machine)
    return MachineSettingsRowLabel(
      name: machine.name,
      sandbox: presence?.ephemeral,
      icon: SidebarGroupIcon.machine(machine.id, in: machines).image,
      connection: connection(for: machine, presence: presence),
      keyChanged: keyChanged(presence),
      onTrustKey: { trustingKey = presence }
    )
    .contextMenu {
      if keyChanged(presence) {
        Button {
          trustingKey = presence
        } label: {
          Label("Trust New Key…", systemImage: "exclamationmark.shield")
        }
      }
      Button {
        editingMachine = presence
      } label: {
        Label("Edit…", systemImage: "pencil")
      }
      Button(role: .destructive) {
        removeMachine(machine)
      } label: {
        Label("Disconnect…", systemImage: "trash")
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      ConfirmingDestructiveButton("Disconnect", systemImage: "trash") { removeMachine(machine) }
        .labelStyle(.iconOnly)
      Button {
        editingMachine = presence
      } label: {
        Image(systemName: "pencil")
      }
      .accessibilityLabel("Edit")
    }
    .modifier(
      MachineRowDialogs(presence: presence, cloud: cloud, removing: $removingCloudMachine, trusting: $trustingKey)
    )
  }

  private func keyChanged(_ presence: CloudMachine?) -> Bool {
    presence.map { cloud.machinesWithChangedKeys.contains($0.deviceId) } ?? false
  }

  private func connection(for machine: CodevisorMachine, presence: CloudMachine?) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      isLocal: machine.isLocal,
      status: machines.statusByMachineId[machine.id],
      availability: machines.availabilityByMachineId[machine.id],
      navigationSyncState: machines.navigationSyncStateByMachineId[machine.id],
      cloud: presence.map { CloudMachineReach(presence: $0, pipes: cloud.directPaths) }
    )
  }
}
