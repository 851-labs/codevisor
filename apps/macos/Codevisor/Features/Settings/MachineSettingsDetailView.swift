import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI

/// Settings ▸ Machines ▸ <machine>: everything that belongs to one machine.
/// Harnesses, MCP servers, and skills push their own pages (like Xcode's
/// per-agent Intelligence pages); the machine's server status and (for this
/// Mac) remote access follow below.
struct MachineSettingsDetailView: View {
    let machineId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var serverStatus: ServerStatusModel?
    @State private var tokenCopied = false
    @State private var tokenError: String?

    private var machine: CodevisorMachine? {
        environment.machines.allMachines.first { $0.id == machineId }
    }

    private var isConnected: Bool {
        machineId == environment.machines.selectedMachineId
    }

    private var displayName: String {
        if let machine, machine.isCloud,
            let presence = environment.machines.cloudMachine(forMachineId: machineId)
        {
            return presence.name
        }
        return machine?.name ?? "Machine"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: machine?.resolvedAppearance.symbolName ?? "desktopcomputer")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(.headline)
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if !isConnected {
                        Button("Connect") {
                            environment.machines.selectMachine(machineId)
                            Task { await environment.machines.refreshStatus(for: machineId) }
                        }
                        .settingsActionTint(theme)
                    }
                }
            }

            Section {
                NavigationLink(value: MachineSettingsRoute.harnesses(machineId)) {
                    Label("Harnesses", systemImage: "cpu")
                }
                NavigationLink(value: MachineSettingsRoute.mcps(machineId)) {
                    Label("MCP Servers", systemImage: "puzzlepiece.extension")
                }
                NavigationLink(value: MachineSettingsRoute.skills(machineId)) {
                    Label("Skills", systemImage: "book.closed")
                }
                NavigationLink(value: MachineSettingsRoute.plugins(machineId)) {
                    Label("Plugins", systemImage: "puzzlepiece")
                }
            }

            Section {
                serverStatusContent
            } header: {
                Text("About")
            }

            if machine?.isLocal == true {
                Section {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connection token")
                            Text(tokenError ?? "Lets another device connect to this Mac.")
                                .font(.callout)
                                .foregroundStyle(
                                    tokenError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                        }
                        Spacer()
                        Button {
                            copyConnectionToken()
                        } label: {
                            if tokenCopied {
                                Label("Copied", systemImage: "checkmark")
                            } else {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                        .settingsActionTint(theme)
                    }
                } header: {
                    Text("Remote Access")
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .navigationTitle(displayName)
        .task(id: machineId) {
            serverStatus = ServerStatusModel(client: environment.machines.client(for: machineId))
            await serverStatus?.refresh()
        }
    }

    private var statusText: String {
        if isConnected { return "Connected" }
        if let machine, machine.isCloud,
            let presence = environment.machines.cloudMachine(forMachineId: machineId)
        {
            return presence.online ? "Online · Codevisor Cloud" : "Offline · Codevisor Cloud"
        }
        if let status = environment.machines.statusByMachineId[machineId] {
            return status.label
        }
        return machine?.baseURL.absoluteString ?? ""
    }

    /// The few facts a user acts on: the version, an update when one exists,
    /// the address of a remote machine, and problems (unreachable server,
    /// running migration). Internal plumbing — server self-name, database
    /// state, local bind host — stays out.
    @ViewBuilder
    private var serverStatusContent: some View {
        if let serverStatus {
            if let errorMessage = serverStatus.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            statusRow("Version", value: serverStatus.info?.version ?? serverStatus.health?.version ?? "—")
            if let machine, !machine.isLocal, !machine.isCloud {
                LabeledContent("Address") {
                    Text(machine.baseURL.absoluteString)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if let update = serverStatus.update, update.updateAvailable {
                HStack {
                    Label("Update available", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(update.currentVersion) → \(update.latestVersion)")
                        .foregroundStyle(.secondary)
                }
            }
            if let update = serverStatus.update, update.migrationState != "idle" {
                statusRow("Migration", value: update.migrationState.capitalized)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    /// Issues a fresh token from this Mac's server and puts it on the
    /// clipboard, for pasting into another device's Add Remote Machine form.
    private func copyConnectionToken() {
        Task {
            do {
                let token = try await environment.machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
                tokenError = nil
                tokenCopied = true
                try? await Task.sleep(for: .seconds(2))
                tokenCopied = false
            } catch {
                tokenError = "Couldn't issue a token: this Mac's server isn't running."
            }
        }
    }
}

#Preview("Machine Detail") {
    NavigationStack {
        MachineSettingsDetailView(machineId: CodevisorMachine.local.id)
    }
    .environment(AppEnvironment.preview())
    .frame(width: 580, height: 560)
}
