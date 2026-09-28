import SwiftUI
import CodevisorCore
import CodevisorUI

/// Settings ▸ Machines: this Mac plus every machine on the Codevisor Cloud
/// account, as a flat list — status and actions live on the rows. There is
/// no per-machine page and no "connect" affordance: the fleet is always
/// connected, and which machine the app points at is a routing detail that
/// follows the chat you open. Machines join by signing in to the account
/// (`codevisor auth login`), never by address.
struct MachinesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.controlActiveState) private var controlActiveState

  @State private var renamingCloud: CloudMachine?
  @State private var removingCloud: CloudMachine?
  @State private var trustingKeyCloud: CloudMachine?

  private var machines: MachineController { environment.machines }

  /// The status poll below runs ONLY while this list can actually be seen:
  /// the Machines section is selected and the Settings window is
  /// key/active. An unguarded `.task` here kept a per-machine HTTP probe
  /// (10s) running for the rest of the app's lifetime — even with the
  /// window closed. `.task(id:)` restarts the loop (with an immediate
  /// refresh) the moment the list becomes visible again.
  private var isPollingActive: Bool {
    controlActiveState != .inactive
      && SettingsRouter.shared.selectedTab == .machines
  }

  /// A Bool presentation binding over optional state ("present while
  /// non-nil"), kept out of `body` so the Release type-checker stays within
  /// its budget.
  private func presenceBinding<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(
      get: { state.wrappedValue != nil },
      set: { if !$0 { state.wrappedValue = nil } }
    )
  }

  /// The machine list itself, separated from `body`'s presentation-modifier
  /// chain: as one expression the two together exceeded the Release
  /// type-checker's budget ("unable to type-check this expression in
  /// reasonable time" in Alpha builds).
  private var machinesForm: some View {
    Form {
      Section {
        // This Mac plus the cloud account's machines, deduplicated in
        // the controller (this Mac's own cloud registration is hidden).
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
    }
    .settingsPaneFormStyle(theme)
  }

  var body: some View {
    machinesForm
      .sheet(item: $renamingCloud) { machine in
        RenameCloudMachineSheet(machine: machine) { name in
          Task { await environment.cloud.rename(deviceId: machine.deviceId, name: name) }
        }
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
        .settingsActionTint(theme)
        Button("Cancel", role: .cancel) {}
          .settingsActionTint(theme)
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
        .settingsActionTint(theme)
        Button("Cancel", role: .cancel) {}
          .settingsActionTint(theme)
      } message: { machine in
        Text(
          "“\(machine.name)” is presenting a different encryption key than the one this device remembers. That happens if the machine was re-provisioned — but it can also mean something between you and the machine is intercepting traffic. Only trust the new key if you expected this change."
        )
      }
      // Keep statuses honest while the pane is open: a machine that was mid
      // restart (or briefly offline) when first probed recovers on the next
      // pass instead of staying stuck on "Unreachable". No probes while
      // nobody is looking.
      .task(id: isPollingActive) {
        guard isPollingActive else { return }
        while !Task.isCancelled {
          await refreshStatuses()
          try? await Task.sleep(for: .seconds(10))
        }
      }
  }
}

// Row/label builders live in a private extension so the struct body stays
// within the structural lint limits.
private extension MachinesSettingsView {
  /// A machine reached through the cloud account's relay (row extracted to
  /// CloudMachineRowView; the sheets/dialogs it triggers live on this list).
  func cloudMachineRow(_ machine: CodevisorMachine, presence: CloudMachine) -> some View {
    CloudMachineRowView(
      machine: machine,
      presence: presence,
      keyChanged: environment.cloud.machinesWithChangedKeys.contains(presence.deviceId),
      connection: connection(for: machine, presence: presence),
      onRename: { renamingCloud = presence },
      onRemove: { removingCloud = presence },
      onTrustKey: { trustingKeyCloud = presence }
    )
  }

  /// This Mac's own row (the embedded machine): its name follows the
  /// computer name, so there is nothing to rename or remove.
  func machineRow(_ machine: CodevisorMachine) -> some View {
    HStack(spacing: 10) {
      Image(systemName: EntitySystemSymbol.machine(machine))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(theme.textPrimary)
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
    }
    .accessibilityElement(children: .combine)
  }

  func statusLabel(_ machine: CodevisorMachine) -> some View {
    let status = machines.statusByMachineId[machine.id]
    // An unreachable machine's probe error (e.g. the local server's launch failure) stays
    // available as the tooltip; the label says Offline.
    return MachineConnectionBadge(connection(for: machine, presence: nil))
      .help(status?.isReachable == false ? status?.label ?? "" : "")
  }

  /// One connection presentation for every kind of machine row.
  func connection(for machine: CodevisorMachine, presence: CloudMachine?) -> MachineConnectionPresentation {
    MachineConnectionPresentation(
      isLocal: machine.isLocal,
      status: machines.statusByMachineId[machine.id],
      availability: machines.availabilityByMachineId[machine.id],
      navigationSyncState: machines.navigationSyncStateByMachineId[machine.id],
      cloud: presence.map { CloudMachineReach(presence: $0, pipes: environment.cloud.directPaths) }
    )
  }

  func refreshStatuses() async {
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
