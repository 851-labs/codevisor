import SwiftUI
import HerdManCore

/// Machines settings — every HerdMan server this app knows about: connect to
/// one, add remotes, rename them, or remove ones you no longer use.
struct MachinesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var showingAdd = false
    @State private var renaming: HerdManMachine?
    @State private var removing: HerdManMachine?

    private var machines: MachineController { environment.machines }

    var body: some View {
        Form {
            Section {
                ForEach(machines.machines) { machine in
                    machineRow(machine)
                }
            } header: {
                Text("Machines")
            } footer: {
                Text("Each machine runs its own HerdMan server; chats, projects, and terminals live on the machine that owns them. Removing a machine only makes this app forget it.")
            }

            Section {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Remote Machine…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAdd) {
            RemoteMachineSheet { host, name in
                if (try? machines.addRemote(host: host, name: name)) != nil {
                    Task { await machines.refreshStatus(for: machines.selectedMachineId) }
                }
            }
        }
        .sheet(item: $renaming) { machine in
            RenameMachineSheet(machine: machine) { name in
                try? machines.renameMachine(machine.id, to: name)
            }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible,
            presenting: removing
        ) { machine in
            Button("Remove Machine", role: .destructive) {
                try? machines.removeMachine(machine.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { machine in
            Text("HerdMan will forget “\(machine.name)”. Nothing on the machine itself is changed.")
        }
        .task { await refreshStatuses() }
    }

    private func machineRow(_ machine: HerdManMachine) -> some View {
        let isSelected = machine.id == machines.selectedMachineId
        return HStack(spacing: 10) {
            Image(systemName: machine.isLocal ? "desktopcomputer" : "network")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(machine.name)
                        .fontWeight(.medium)
                    if isSelected {
                        Text("Connected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.15)))
                            .foregroundStyle(.tint)
                    }
                }
                Text(machine.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            statusLabel(machine)
            if !isSelected {
                Button("Connect") {
                    machines.selectMachine(machine.id)
                }
                .controlSize(.small)
            }
            if !machine.isLocal {
                Menu {
                    Button("Rename…") { renaming = machine }
                    Divider()
                    Button("Remove…", role: .destructive) { removing = machine }
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
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusLabel(_ machine: HerdManMachine) -> some View {
        if let status = machines.statusByMachineId[machine.id] {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.isReachable ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(status.isReachable ? status.label : "Unreachable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityLabel(status.isReachable ? "Reachable, \(status.label)" : "Unreachable")
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }

    private func refreshStatuses() async {
        for machine in machines.machines {
            await machines.refreshStatus(for: machine.id)
        }
    }
}

#Preview("Machines") {
    MachinesSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 520, height: 420)
}
