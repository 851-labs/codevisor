import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Machines

/// Machine management: the paired remote machines (never the on-device
/// "local" pseudo-machine — this client has no local server). Each machine
/// nests its own scoped settings: status, harnesses, MCPs, skills.
struct MachinesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isAddingMachine = false
    @State private var isAddingDevelopmentMachine = false
    @State private var developmentError: String?
    @State private var discovery = TailnetMachineDiscovery()
    @State private var discoveredTarget: TailnetMachineDiscovery.Discovered?

    private var machines: MachineController { environment.machines }

    private var remoteMachines: [CodevisorMachine] {
        machines.allMachines.filter { !$0.isLocal }
    }

    var body: some View {
        List {
            Section {
                ForEach(remoteMachines, id: \.id) { machine in
                    NavigationLink {
                        MachineDetailScreen(machineId: machine.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: machine.resolvedAppearance.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                Text(machines.statusByMachineId[machine.id]?.label ?? machine.baseURL.absoluteString)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if machine.id == machines.selectedMachineId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                InlineCodeText("Run `codevisor setup` on a machine to print its address and token.")
            }
            if !discovery.discovered.isEmpty {
                Section {
                    ForEach(discovery.discovered) { machine in
                        discoveredRow(machine)
                    }
                } header: {
                    Text("On Your Tailnet")
                } footer: {
                    Text("Codevisor servers found on your tailnet. Adding one still needs its connection token.")
                }
            }
            Section {
                Button {
                    isAddingMachine = true
                } label: {
                    Label("Add Machine…", systemImage: "plus")
                }
            }
            if let devRemote = CodevisorAppVariant.developmentRemote,
                developmentMachine(devRemote) == nil
            {
                developmentSection(devRemote)
            }
        }
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingMachine) {
            AddMachineSheet()
        }
        .sheet(item: $discoveredTarget) { machine in
            AddMachineSheet(initialHost: machine.host, initialName: machine.name)
        }
        // Discover only while this screen is on screen — no background polling.
        .task {
            while !Task.isCancelled {
                await discovery.refresh(machines: machines)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // A removed machine may be discoverable again (and a just-added one
        // must leave the list) — refresh whenever the machine list changes.
        .onChange(of: machines.machines.map(\.id)) { _, _ in
            Task { await discovery.refresh(machines: machines) }
        }
    }

    private func discoveredRow(_ machine: TailnetMachineDiscovery.Discovered) -> some View {
        Button {
            discoveredTarget = machine
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name)
                        .foregroundStyle(.primary)
                    Text("\(machine.host) · Codevisor \(machine.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    /// Dev-only shortcut, as on macOS: one tap adds the dev remote that
    /// `bun run dev:ios` started, no token entry. Hidden once it's paired —
    /// remove it like any other machine from its detail page.
    private func developmentSection(_ remote: CodevisorAppVariant.DevelopmentRemote) -> some View {
        Section {
            Button {
                Task { await addDevelopmentMachine(remote) }
            } label: {
                Label("Add Development Machine", systemImage: "bolt.fill")
            }
            .disabled(isAddingDevelopmentMachine)
        } header: {
            Text("Development")
        } footer: {
            if let developmentError {
                Text(developmentError)
                    .foregroundStyle(.red)
            } else {
                Text("\(remote.name) at \(remote.hostWithPort), started by bun run dev:ios.")
            }
        }
    }

    /// The registered machine matching the dev remote (by host + port), if
    /// it has been added — the section hides itself once paired.
    private func developmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) -> CodevisorMachine? {
        machines.machines.first { machine in
            machine.baseURL.host() == remote.host
                && (machine.baseURL.port ?? CodevisorAppVariant.productionPort) == remote.port
        }
    }

    private func addDevelopmentMachine(_ remote: CodevisorAppVariant.DevelopmentRemote) async {
        isAddingDevelopmentMachine = true
        developmentError = nil
        defer { isAddingDevelopmentMachine = false }
        do {
            let added = try await machines.addRemoteValidating(
                host: remote.hostWithPort,
                name: remote.name,
                token: remote.token
            )
            machines.selectMachine(added.id)
            await environment.prepareSelectedMachine()
        } catch {
            developmentError = ErrorReporter.userFacingMessage(for: error)
        }
    }
}
