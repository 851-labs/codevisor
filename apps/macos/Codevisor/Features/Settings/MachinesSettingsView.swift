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
/// one, customize its identity, add remotes, rename them, or remove ones you
/// no longer use.
struct MachinesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    @State private var showingAdd = false
    @State private var discovery = MachineDiscoveryService()
    @State private var addingDiscovered: DiscoveredMachine?
    @State private var renaming: CodevisorMachine?
    @State private var iconEditing: CodevisorMachine?
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
            if discovery.isAvailable && !discovery.discovered.isEmpty {
                Section {
                    ForEach(discovery.discovered) { machine in
                        discoveredRow(machine)
                    }
                } header: {
                    Text("On Your Network")
                }
            }
            if let devRemote = CodevisorAppVariant.developmentRemote {
                developmentSection(devRemote)
            }
        }
        .settingsPaneFormStyle(theme)
        // Discover only while this pane is on screen; no background polling.
        .task {
            while !Task.isCancelled {
                await discovery.refresh(registeredHosts: registeredHosts)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // The Settings window persists, so `.task` only runs once. Refetch
        // whenever this tab is (re)selected — e.g. via "Manage Machines" — and
        // whenever the machine list changes, so discovery reflects reality.
        .onChange(of: SettingsRouter.shared.selectedTab) { _, tab in
            guard tab == .machines else { return }
            Task {
                await discovery.refresh(registeredHosts: registeredHosts)
                await refreshStatuses()
            }
        }
        .onChange(of: machines.machines.map(\.id)) { _, _ in
            Task { await discovery.refresh(registeredHosts: registeredHosts) }
        }
        .sheet(item: $addingDiscovered) { machine in
            RemoteMachineSheet(name: machine.name, host: machine.host) { host, name, token in
                await addMachine(host: host, name: name, token: token)
            }
        }
        .sheet(isPresented: $showingAdd) {
            RemoteMachineSheet { host, name, token in
                await addMachine(host: host, name: name, token: token)
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
        .sheet(item: $iconEditing) { machine in
            IconPickerView(currentSymbol: machine.resolvedAppearance.symbolName) { symbol in
                machines.setAppearance(MachineAppearance(symbolName: symbol), for: machine.id)
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
                    // A removed machine may be discoverable again — refetch so
                    // it reappears under "On Your Network" right away.
                    Task { await discovery.refresh(registeredHosts: registeredHosts) }
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
        // Keep statuses honest while the pane is open: a machine that was mid
        // restart (or briefly offline) when first probed recovers on the next
        // pass instead of staying stuck on "Unreachable".
        .task {
            while !Task.isCancelled {
                await refreshStatuses()
                try? await Task.sleep(for: .seconds(10))
            }
        }
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

    /// Hosts already in the machine list, so discovery skips them.
    private var registeredHosts: Set<String> {
        Set(machines.machines.compactMap { $0.baseURL.host })
    }

    /// Validates and adds a machine, returning an error message for the Add
    /// dialog to show inline (nil on success). On success it re-runs discovery
    /// so a just-added network peer drops out of the suggestions immediately.
    private func addMachine(host: String, name: String?, token: String?) async -> String? {
        do {
            try await machines.addRemoteValidating(host: host, name: name, token: token)
            await discovery.refresh(registeredHosts: registeredHosts)
            return nil
        } catch {
            Log.machines.error("Adding machine failed: \(String(describing: error), privacy: .public)")
            if case CodevisorServerClientError.httpStatus(401, _) = error {
                return "That connection token was rejected by the machine. Check it with `codevisor token` and try again."
            }
            return serverErrorMessage(error)
        }
    }

    /// Dev-only shortcut: one click adds the standalone "Dev Remote" server
    /// that `bun run dev` starts (no token entry), plus its connection details
    /// so the manual add / deeplink flows can be exercised too.
    @ViewBuilder
    private func developmentSection(_ remote: CodevisorAppVariant.DevelopmentRemote) -> some View {
        Section {
            debugRow("Host", remote.hostWithPort)
            debugRow("Token", remote.token)
            debugRow("Deeplink", remote.deeplink)

            if let existing = developmentMachine(remote) {
                Button(role: .destructive) {
                    try? machines.removeMachine(existing.id)
                } label: {
                    Label("Remove Development Machine", systemImage: "trash")
                }
                .settingsActionTint(theme)
            } else {
                Button {
                    Task {
                        _ = await addMachine(host: remote.hostWithPort, name: remote.name, token: remote.token)
                    }
                } label: {
                    Label("Add Development Machine…", systemImage: "bolt.fill")
                }
                .settingsActionTint(theme)
            }
        } header: {
            Text("Development")
        }
    }

    /// The registered machine matching the dev remote (by host + port), if it
    /// has been added — so the section can offer Remove instead of Add.
    private func developmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) -> CodevisorMachine? {
        machines.machines.first { machine in
            machine.baseURL.host == remote.host
                && (machine.baseURL.port ?? CodevisorAppVariant.productionPort) == remote.port
        }
    }

    /// A monospaced, selectable value with a copy button — for pasting dev
    /// connection details into the other add flows.
    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tooltip("Copy \(label)")
            .accessibilityLabel("Copy \(label)")
        }
    }

    private func discoveredRow(_ machine: DiscoveredMachine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: machine.os == "linux" ? "server.rack" : "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                Text("\(machine.host) · Codevisor \(machine.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add…") {
                addingDiscovered = machine
            }
            .settingsActionTint(theme)
        }
        .padding(.vertical, 2)
    }

    private func machineRow(_ machine: CodevisorMachine) -> some View {
        let isSelected = machine.id == machines.selectedMachineId
        return HStack(spacing: 10) {
            Image(systemName: machine.resolvedAppearance.symbolName)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.textPrimary)
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
                    Task { await machines.refreshStatus(for: machine.id) }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
            }
            if machine.isLocal {
                Menu {
                    Button("Change icon") { iconEditing = machine }
                    Divider()
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
                .tooltip("Machine actions")
                .accessibilityLabel("Actions for \(machine.name)")
            } else {
                Menu {
                    Button("Change icon") { iconEditing = machine }
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
                .tooltip("Machine actions")
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
