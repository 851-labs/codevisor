import SwiftUI
import AppKit
import CodevisorCore
import os

/// A failed machine action (add/rename/remove), pending display in an alert.
private struct MachineActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Machines settings — every Codevisor server this app knows about: connect to
/// one, add remotes, rename them, or remove ones you no longer use.
struct MachinesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    @State private var showingAdd = false
    @State private var renaming: CodevisorMachine?
    @State private var removing: CodevisorMachine?
    @State private var tokenNotice: String?
    @State private var actionError: MachineActionError?

    private var machines: MachineController { environment.machines }

    var body: some View {
        Form {
            Section {
                ForEach(machines.machines) { machine in
                    machineRow(machine)
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Remote Machine…", systemImage: "plus")
                }
                .settingsActionTint(theme)
            } header: {
                Text("Machines")
            }
        }
        .settingsPaneFormStyle(theme)
        .sheet(isPresented: $showingAdd) {
            RemoteMachineSheet { host, name, token in
                do {
                    try machines.addRemote(host: host, name: name, token: token)
                    Task { await machines.refreshStatus(for: machines.selectedMachineId) }
                } catch {
                    Log.machines.error("Adding remote machine failed: \(String(describing: error), privacy: .public)")
                    actionError = MachineActionError(
                        title: "Couldn't Add the Machine",
                        message: ErrorReporter.userFacingMessage(for: error)
                    )
                }
            }
        }
        .sheet(item: $renaming) { machine in
            RenameMachineSheet(machine: machine) { name in
                do {
                    try machines.renameMachine(machine.id, to: name)
                } catch {
                    Log.machines.error("Renaming machine failed: \(String(describing: error), privacy: .public)")
                    actionError = MachineActionError(
                        title: "Couldn't Rename the Machine",
                        message: ErrorReporter.userFacingMessage(for: error)
                    )
                }
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
                do {
                    try machines.removeMachine(machine.id)
                } catch {
                    Log.machines.error("Removing machine failed: \(String(describing: error), privacy: .public)")
                    actionError = MachineActionError(
                        title: "Couldn't Remove the Machine",
                        message: ErrorReporter.userFacingMessage(for: error)
                    )
                }
            }
            .settingsActionTint(theme)
            Button("Cancel", role: .cancel) {}
                .settingsActionTint(theme)
        } message: { machine in
            Text("Codevisor will forget “\(machine.name)”. Nothing on the machine itself is changed.")
        }
        .task { await refreshStatuses() }
        .alert(
            "Connection Token",
            isPresented: Binding(
                get: { tokenNotice != nil },
                set: { if !$0 { tokenNotice = nil } }
            ),
            presenting: tokenNotice
        ) { _ in
            Button("OK") {}
                .settingsActionTint(theme)
        } message: { notice in
            Text(notice)
        }
        .alert(
            actionError?.title ?? "",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK") {}
                .settingsActionTint(theme)
        } message: { error in
            Text(error.message)
        }
    }

    /// Issues a fresh token from this machine's server and puts it on the
    /// clipboard, for pasting into another device's Add Remote Machine sheet.
    private func copyConnectionToken() {
        Task {
            do {
                let token = try await machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
                tokenNotice = "Copied to the clipboard. Paste it into “Add Remote Machine” on the other device to let it connect to this Mac."
            } catch {
                tokenNotice = "Couldn't issue a token: the local server isn't running."
            }
        }
    }

    private func machineRow(_ machine: CodevisorMachine) -> some View {
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
                            .background(Capsule().fill(theme.accent.opacity(0.15)))
                            .foregroundStyle(theme.textPrimary)
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
                .settingsActionTint(theme)
                .controlSize(.small)
            }
            if machine.isLocal {
                Menu {
                    Button("Copy Connection Token") { copyConnectionToken() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .settingsActionTint(theme)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Machine actions")
                .accessibilityLabel("Actions for \(machine.name)")
            } else {
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
                .settingsActionTint(theme)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Machine actions")
                .accessibilityLabel("Actions for \(machine.name)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusLabel(_ machine: CodevisorMachine) -> some View {
        if let status = machines.statusByMachineId[machine.id] {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.isReachable ? theme.statusOK : theme.statusError)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                // The label carries the failure reason when unreachable (e.g.
                // the local server's launch error), not just "Unreachable".
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityLabel(status.isReachable ? "Reachable, \(status.label)" : status.label)
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
