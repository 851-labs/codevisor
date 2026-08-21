import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI

/// Settings ▸ Machines ▸ <machine>: everything that belongs to one machine.
/// Harnesses, MCP servers, and skills push their own pages (like Xcode's
/// per-agent Intelligence pages); this Mac's remote access follows below.
struct MachineSettingsDetailView: View {
    let machineId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
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
                    Image(
                        systemName: machine.map(EntitySystemSymbol.machine)
                            ?? EntitySystemSymbol.machine(.local)
                    )
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
                    settingsNavigationLabel("Harnesses", systemImage: "cpu")
                }
                NavigationLink(value: MachineSettingsRoute.mcps(machineId)) {
                    settingsNavigationLabel("MCP Servers", systemImage: "puzzlepiece.extension")
                }
                NavigationLink(value: MachineSettingsRoute.skills(machineId)) {
                    settingsNavigationLabel("Skills", systemImage: "book.closed")
                }
                NavigationLink(value: MachineSettingsRoute.plugins(machineId)) {
                    settingsNavigationLabel("Plugins", systemImage: "puzzlepiece")
                }
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

    private func settingsNavigationLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
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
