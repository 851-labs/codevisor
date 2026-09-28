import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

// MARK: - Machines

/// Machine management: the machines on the Codevisor Cloud account (never
/// the on-device "local" pseudo-machine — this client has no local server),
/// as a flat list — rename and disconnect live on the rows. There is no
/// per-machine page and no selection affordance: the fleet is always
/// connected, and which machine the app points at follows the chat you open.
struct MachinesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var renamingMachine: CodevisorMachine?
  @State private var renameText = ""
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
    .alert("Rename Machine", isPresented: renamePresented, presenting: renamingMachine) { machine in
      TextField("Name", text: $renameText)
      Button("Rename") {
        if let presence = cloudMachine(for: machine) {
          let name = renameText
          Task { await cloud.rename(deviceId: presence.deviceId, name: name) }
        }
        renamingMachine = nil
      }
      Button("Cancel", role: .cancel) { renamingMachine = nil }
    }
    .task {
      while !Task.isCancelled {
        await cloud.refreshMachines()
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  private var renamePresented: Binding<Bool> {
    Binding(
      get: { renamingMachine != nil },
      set: { if !$0 { renamingMachine = nil } }
    )
  }

  private func cloudMachine(for machine: CodevisorMachine) -> CloudMachine? {
    machines.cloudMachine(forMachineId: machine.id)
  }

  private func removeMachine(_ machine: CodevisorMachine) {
    removingCloudMachine = cloudMachine(for: machine)
  }

  /// Reachability and sync failures must remain visible even when the cloud
  /// roster says the host is online.
  private func machineRow(_ machine: CodevisorMachine) -> some View {
    let presence = cloudMachine(for: machine)
    let connection = MachineConnectionPresentation(
      isLocal: machine.isLocal,
      status: machines.statusByMachineId[machine.id],
      availability: machines.availabilityByMachineId[machine.id],
      navigationSyncState: machines.navigationSyncStateByMachineId[machine.id],
      cloud: presence.map { CloudMachineReach(presence: $0, pipes: cloud.directPaths) }
    )
    return HStack(spacing: 10) {
      Image(systemName: EntitySystemSymbol.machine(machine))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(machine.name)
      Spacer(minLength: 10)
      if let presence, cloud.machinesWithChangedKeys.contains(presence.deviceId) {
        Button {
          trustingKey = presence
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.shield.fill")
              .accessibilityHidden(true)
            Text("Key Changed")
              .font(.footnote)
          }
          .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
      } else {
        MachineConnectionBadge(connection, font: .footnote)
      }
    }
    .accessibilityElement(children: .combine)
    .contentShape(Rectangle())
    .contextMenu {
      if let presence, cloud.machinesWithChangedKeys.contains(presence.deviceId) {
        Button {
          trustingKey = presence
        } label: {
          Label("Trust New Key…", systemImage: "exclamationmark.shield")
        }
      }
      Button("Rename…") {
        renameText = machine.name
        renamingMachine = machine
      }
      Button("Disconnect…", role: .destructive) {
        removeMachine(machine)
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
        renameText = machine.name
        renamingMachine = machine
      } label: {
        Image(systemName: "pencil")
      }
      .accessibilityLabel("Rename")
    }
    // Anchored to this row so an iPad popover points at the machine it
    // asks about rather than the middle of the screen.
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
