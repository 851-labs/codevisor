import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

struct MachinesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
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

  private func connectionText(_ connection: MachineConnectionPresentation) -> Text {
    let dot = Text(Image(systemName: "circlebadge.fill"))
      .font(.caption2)
      .foregroundStyle(connection.indicator == .connected ? theme.statusOK : .gray)
    return Text("\(dot) \(connection.label())")
  }

  private func machineRow(_ machine: CodevisorMachine) -> some View {
    let presence = cloudMachine(for: machine)
    let connection = MachineConnectionPresentation(
      isLocal: machine.isLocal,
      status: machines.statusByMachineId[machine.id],
      availability: machines.availabilityByMachineId[machine.id],
      navigationSyncState: machines.navigationSyncStateByMachineId[machine.id],
      cloud: presence.map { CloudMachineReach(presence: $0, pipes: cloud.directPaths) }
    )
    let keyChanged = presence.map { cloud.machinesWithChangedKeys.contains($0.deviceId) } ?? false
    return Label {
      Text(machine.name)
      if keyChanged {
        Text("\(Image(systemName: "exclamationmark.shield.fill")) Key Changed")
          .foregroundStyle(.orange)
      } else {
        connectionText(connection)
      }
    } icon: {
      Image(systemName: machine.icon.systemImage)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(keyChanged ? .isButton : [])
    .contentShape(Rectangle())
    .onTapGesture {
      if keyChanged { trustingKey = presence }
    }
    .contextMenu {
      if let presence, cloud.machinesWithChangedKeys.contains(presence.deviceId) {
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
      Button(role: .destructive) {
        removeMachine(machine)
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Disconnect")
      Button {
        editingMachine = presence
      } label: {
        Image(systemName: "pencil")
      }
      .accessibilityLabel("Edit")
    }
    .confirmationDialog(
      "Disconnect “\(removingCloudMachine?.name ?? "")”?",
      isPresented: Binding(
        get: { presence != nil && removingCloudMachine?.deviceId == presence?.deviceId },
        set: { if !$0 { removingCloudMachine = nil } }
      ),
      titleVisibility: .visible,
      presenting: removingCloudMachine
    ) { machine in
      Button("Disconnect Machine", role: .destructive) {
        Task { await cloud.remove(deviceId: machine.deviceId) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { machine in
      Text(
        "“\(machine.name)” will be signed out of your account. Nothing on the machine itself is changed — run codevisor auth login there to reconnect it."
      )
    }
    .confirmationDialog(
      "Trust the new key for “\(trustingKey?.name ?? "")”?",
      isPresented: Binding(
        get: { presence != nil && trustingKey?.deviceId == presence?.deviceId },
        set: { if !$0 { trustingKey = nil } }
      ),
      titleVisibility: .visible,
      presenting: trustingKey
    ) { machine in
      Button("Trust New Key", role: .destructive) {
        cloud.trustChangedMachineKey(deviceId: machine.deviceId)
      }
      Button("Cancel", role: .cancel) {}
    } message: { machine in
      Text(
        "“\(machine.name)” is presenting a different encryption key than the one this device remembers. That happens if the machine was re-provisioned — but it can also mean something between you and the machine is intercepting traffic. Only trust the new key if you expected this change."
      )
    }
  }
}
