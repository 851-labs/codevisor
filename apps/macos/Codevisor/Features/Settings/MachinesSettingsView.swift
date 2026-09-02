import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import os
import CodevisorUI

/// A failed machine action (add/rename/remove), pending display in an alert.
private struct MachineActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Settings ▸ Machines: every Codevisor server this app knows about, as a
/// flat list — status, actions, and removal all live on the rows. There is
/// no per-machine page and no "connect" affordance: the fleet is always
/// connected, and which machine the app points at is a routing detail that
/// follows the chat you open. The cloud account, network discovery, and the
/// dev remote live here as list sections.
struct MachinesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var showingAdd = false
    @State private var discovery = MachineDiscoveryService()
    @State private var addingDiscovered: DiscoveredMachine?
    @State private var renaming: CodevisorMachine?
    @State private var removing: CodevisorMachine?
    @State private var tokenNotice: String?
    @State private var actionError: MachineActionError?
    @State private var renamingCloud: CloudMachine?
    @State private var removingCloud: CloudMachine?
    @State private var trustingKeyCloud: CloudMachine?

    private var machines: MachineController { environment.machines }

    /// The polls below run ONLY while this list can actually be seen: the
    /// Machines section is selected, no machine page is pushed over it, and
    /// the Settings window is key/active. An unguarded `.task` here kept a
    /// `tailscale status` subprocess (30s) and a serial per-machine HTTP
    /// probe (10s) running for the rest of the app's lifetime — even with
    /// the window closed. `.task(id:)` restarts the loops (with an immediate
    /// refresh) the moment the list becomes visible again.
    private var isPollingActive: Bool {
        controlActiveState != .inactive
            && SettingsRouter.shared.selectedTab == .machines
    }

    /// A Bool presentation binding over optional state ("present while
    /// non-nil"). Extracted from `body`: five of these inlined as closure
    /// pairs were the heaviest part of the expression the Release
    /// type-checker gave up on.
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
                // One list for every machine, however it arrives: configured
                // (local + remote) machines plus cloud-relay machines the
                // account knows about, deduplicated in the controller.
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
                SettingsListActions {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Remote Machine…", systemImage: "plus")
                    }
                    .settingsActionTint(theme)
                }
            }
            // The cloud account (sign-in, self-hosted server) as its own
            // "Cloud" section.
            CloudSettingsView()
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
    }

    /// Layer 1 of `body` (split so each expression stays inside the Release
    /// type-checker's budget; one flat chain provably exceeds it in CI).
    private var withDiscoveryTasks: some View {
        machinesForm
            .task(id: isPollingActive) {
                guard isPollingActive else { return }
                while !Task.isCancelled {
                    await discovery.refresh(registeredHosts: registeredHosts)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: machines.machines.map(\.id)) { _, _ in
                Task { await discovery.refresh(registeredHosts: registeredHosts) }
            }
    }

    /// Layer 2: cloud machine sheets and dialogs.
    private var withCloudPresentations: some View {
        withDiscoveryTasks
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
    }

    /// Layer 3: add/rename machine sheets.
    private var withMachineSheets: some View {
        withCloudPresentations
            .sheet(item: $addingDiscovered) { machine in
                RemoteMachineSheet(name: machine.name, host: machine.host) {
                    host, name, token, syncConfig in
                    await addMachine(host: host, name: name, token: token, syncConfig: syncConfig)
                }
            }
            .sheet(isPresented: $showingAdd) {
                RemoteMachineSheet { host, name, token, syncConfig in
                    await addMachine(host: host, name: name, token: token, syncConfig: syncConfig)
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
    }

    var body: some View {
        withMachineSheets
            .confirmationDialog(
                "Remove “\(removing?.name ?? "")”?",
                isPresented: presenceBinding($removing),
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
            // pass instead of staying stuck on "Unreachable". Gated exactly like
            // discovery above — no probes while nobody is looking.
            .task(id: isPollingActive) {
                guard isPollingActive else { return }
                while !Task.isCancelled {
                    await refreshStatuses()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .alert(
                "Connection Token",
                isPresented: presenceBinding($tokenNotice),
                presenting: tokenNotice
            ) { _ in
                Button("OK") {}
                    .settingsActionTint(theme)
            } message: { notice in
                Text(notice)
            }
            .alert(
                actionError?.title ?? "",
                isPresented: presenceBinding($actionError),
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
                tokenNotice =
                    "Copied to the clipboard. Paste it into “Add Remote Machine” on the other device to let it connect to this Mac."
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
    private func addMachine(
        host: String,
        name: String?,
        token: String?,
        syncConfig: Bool = true
    ) async -> String? {
        do {
            let machine = try await machines.addRemoteValidating(
                host: host, name: name, token: token, syncConfig: syncConfig)
            environment.composerDefaults.rememberNewWorkspaceServer(serverId: machine.id)
            await discovery.refresh(registeredHosts: registeredHosts)
            return nil
        } catch {
            Log.machines.error("Adding machine failed: \(String(describing: error), privacy: .public)")
            if case CodevisorServerClientError.httpStatus(401, _) = error {
                return
                    "That connection token was rejected by the machine. Check it with `codevisor token` and try again."
            }
            return serverErrorMessage(error)
        }
    }

    /// Dev-only shortcut: one click adds the standalone "Dev Direct" server
    /// that `bun run dev` starts (no token entry), plus its connection details
    /// so the manual add / deeplink flows can be exercised too. The "Dev
    /// Cloud" server has no entry here on purpose — it arrives through the
    /// dev cloud account, exercising the relay path.
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
                    Label("Remove \(remote.name)", systemImage: "trash")
                }
                .settingsActionTint(theme)
            } else {
                Button {
                    Task {
                        _ = await addMachine(host: remote.hostWithPort, name: remote.name, token: remote.token)
                    }
                } label: {
                    Label("Add \(remote.name)…", systemImage: "bolt.fill")
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
            .help("Copy \(label)")
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
            direct: environment.cloud.directPaths.machineIds.contains(presence.deviceId),
            onRename: { renamingCloud = presence },
            onRemove: { removingCloud = presence },
            onTrustKey: { trustingKeyCloud = presence }
        )
    }

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
    func statusLabel(_ machine: CodevisorMachine) -> some View {
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
