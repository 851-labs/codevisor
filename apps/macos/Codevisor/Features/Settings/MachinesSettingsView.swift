import SwiftUI
import CodevisorCore
import CodevisorUI

struct MachinesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.controlActiveState) private var controlActiveState

  @State private var editingCloud: CloudMachine?
  @State private var disconnectingAfterEdit: CloudMachine?
  @State private var removingCloud: CloudMachine?
  @State private var trustingKeyCloud: CloudMachine?

  private var machines: MachineController { environment.machines }

  private var isPollingActive: Bool {
    controlActiveState != .inactive
      && SettingsRouter.shared.selectedTab == .machines
  }

  private func presenceBinding<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(
      get: { state.wrappedValue != nil },
      set: { if !$0 { state.wrappedValue = nil } }
    )
  }

  private var machinesForm: some View {
    Form {
      Section {
        ForEach(machines.allMachines) { machine in
          if machine.isCloud,
            let presence = machines.cloudMachine(forMachineId: machine.id)
          {
            cloudMachineRow(machine, presence: presence)
          } else {
            machineRow(machine)
          }
        }
      } header: {
        Text("Machines")
      } footer: {
        Text(
          "To add a machine, install Codevisor on it and run `codevisor auth login` to sign in to your Codevisor Cloud account."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Connect over LAN", isOn: localNetworkBinding)
      } footer: {
        Text("Connect to your machines directly over the local network when available.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var localNetworkBinding: Binding<Bool> {
    Binding(
      get: { environment.localNetworkAccess == .requested },
      set: { environment.setLocalNetworkAccess($0 ? .requested : .deferred) }
    )
  }

  var body: some View {
    machinesForm
      .sheet(item: $editingCloud, onDismiss: presentDisconnectAfterEdit) { machine in
        let isLocal = machine.deviceId == machines.localCloudMachine?.deviceId
        EditMachineSheet(
          machine: machine,
          icon: machines.icon(for: machine),
          isLocal: isLocal,
          onSave: { name, icon in
            Task { await environment.cloud.updateMachine(deviceId: machine.deviceId, name: name, icon: icon) }
          },
          onDisconnect: isLocal ? nil : { disconnectingAfterEdit = machine }
        )
      }
      .confirmationDialog(
        "Disconnect “\(removingCloud?.name ?? "")”?",
        isPresented: presenceBinding($removingCloud),
        titleVisibility: .visible,
        presenting: removingCloud
      ) { machine in
        Button("Disconnect Machine", role: .destructive) {
          Task { await environment.cloud.remove(deviceId: machine.deviceId) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { machine in
        Text(
          "“\(machine.name)” will be signed out of your cloud account. Nothing on the machine itself is changed — run `codevisor auth login` there to reconnect it."
        )
      }
      .confirmationDialog(
        "Trust the new key for “\(trustingKeyCloud?.name ?? "")”?",
        isPresented: presenceBinding($trustingKeyCloud),
        titleVisibility: .visible,
        presenting: trustingKeyCloud
      ) { machine in
        Button("Trust New Key", role: .destructive) {
          environment.cloud.trustChangedMachineKey(deviceId: machine.deviceId)
        }
        Button("Cancel", role: .cancel) {}
      } message: { machine in
        Text(
          "“\(machine.name)” is presenting a different encryption key than the one this device remembers. That happens if the machine was re-provisioned — but it can also mean something between you and the machine is intercepting traffic. Only trust the new key if you expected this change."
        )
      }
      .task(id: isPollingActive) {
        guard isPollingActive else { return }
        while !Task.isCancelled {
          await refreshStatuses()
          try? await Task.sleep(for: .seconds(10))
        }
      }
  }
  fileprivate func cloudMachineRow(_ machine: CodevisorMachine, presence: CloudMachine) -> some View {
    CloudMachineRowView(
      machine: machine,
      presence: presence,
      keyChanged: environment.cloud.machinesWithChangedKeys.contains(presence.deviceId),
      connection: connection(for: machine, presence: presence),
      onEdit: { editingCloud = presence },
      onRemove: { removingCloud = presence },
      onTrustKey: { trustingKeyCloud = presence }
    )
  }

  fileprivate func presentDisconnectAfterEdit() {
    removingCloud = disconnectingAfterEdit
    disconnectingAfterEdit = nil
  }

  fileprivate func machineRow(_ machine: CodevisorMachine) -> some View {
    HStack(spacing: 10) {
      Image(systemName: machine.icon.systemImage)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(machine.name)
          .fontWeight(.medium)
        Text(machine.baseURL.absoluteString)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      statusLabel(machine)
      if machine.isLocal, let presence = machines.localCloudMachine {
        Menu {
          Button("Edit…") { editingCloud = presence }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Machine actions")
        .accessibilityLabel("Actions for \(machine.name)")
      }
    }
    .contextMenu {
      if machine.isLocal, let presence = machines.localCloudMachine {
        Button("Edit…") { editingCloud = presence }
      }
    }
    .accessibilityElement(children: .combine)
  }

  fileprivate func statusLabel(_ machine: CodevisorMachine) -> some View {
    let status = machines.statusByMachineId[machine.id]
    return MachineConnectionBadge(connection(for: machine, presence: nil))
      .help(status?.isReachable == false ? status?.label ?? "" : "")
  }

  fileprivate func connection(for machine: CodevisorMachine, presence: CloudMachine?) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      isLocal: machine.isLocal,
      status: machines.statusByMachineId[machine.id],
      availability: machines.availabilityByMachineId[machine.id],
      navigationSyncState: machines.navigationSyncStateByMachineId[machine.id],
      cloud: presence.map { CloudMachineReach(presence: $0, pipes: environment.cloud.directPaths) }
    )
  }

  fileprivate func refreshStatuses() async {
    await environment.cloud.refreshMachines()
    for machine in machines.machines {
      await machines.refreshStatus(for: machine.id)
    }
  }
}

#Preview("Machines") {
  NavigationStack {
    MachinesSettingsView()
  }
  .environment(AppEnvironment.preview())
  .frame(width: 580, height: 560)
}
