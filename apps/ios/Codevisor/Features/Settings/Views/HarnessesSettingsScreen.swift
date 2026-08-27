import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - Harnesses

struct HarnessesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State var serverId: String
    @State private var harnesses: [ServerHarness] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var signInRequest: HarnessSignInRequest?

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    private var installed: [ServerHarness] {
        harnesses.filter { $0.readiness.state != "notInstalled" }
    }

    private var notInstalled: [ServerHarness] {
        harnesses.filter { $0.readiness.state == "notInstalled" }
    }

    var body: some View {
        List {
            // The pane serves the whole fleet: pick whose install/sign-in
            // state to manage (hidden for single-machine setups).
            if environment.machines.allMachines.count > 1 {
                Section {
                    Picker("Machine", selection: $serverId) {
                        ForEach(environment.machines.allMachines) { machine in
                            Text(machine.name).tag(machine.id)
                        }
                    }
                }
            }
            if isLoading {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Section("Installed") {
                    ForEach(installed, id: \.id) { harness in
                        harnessRow(harness)
                    }
                }
                machinesSection
                if !notInstalled.isEmpty {
                    Section("Not Installed") {
                        ForEach(notInstalled, id: \.id) { harness in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(harness.name)
                                if let hint = harness.installHint {
                                    Text(hint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Harnesses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh harnesses")
            }
        }
        .task(id: serverId) {
            isLoading = true
            await load()
        }
        .harnessSignInSheet(request: $signInRequest)
    }

    /// Phase 24: what each machine reports for the fleet's agents, with
    /// sign-in a tap away. Hidden for single-machine fleets.
    @ViewBuilder
    private var machinesSection: some View {
        let _ = environment.configSync.revisionsByNamespace["harness-readiness"]
        let readiness = HarnessFleet.readiness(environment.configSync)
        if environment.machines.allMachines.count > 1, !readiness.isEmpty {
            Section("On Your Machines") {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    let rows = readiness[machineId] ?? []
                    DisclosureGroup {
                        ForEach(rows) { entry in
                            machineReadinessRow(machineId: machineId, entry: entry)
                        }
                    } label: {
                        HStack {
                            Text(environment.machines.fleetName(forSyncKey: machineId))
                            Spacer(minLength: 12)
                            harnessBadge(rows).view
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func harnessBadge(_ rows: [HarnessFleet.MachineReadiness]) -> MachineSyncBadge {
        if rows.contains(where: { $0.state == "signInRequired" }) {
            return .attention("Sign in required")
        }
        if rows.contains(where: { $0.state == "notInstalled" }) { return .syncing }
        return .synced
    }

    private func machineReadinessRow(
        machineId: String, entry: HarnessFleet.MachineReadiness
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.harnessId)
                Text(entry.reason ?? entry.state)
                    .font(.footnote)
                    .foregroundStyle(entry.state == "signInRequired" ? .orange : .secondary)
            }
            Spacer()
            if entry.state == "signInRequired" {
                Button("Sign In") {
                    if let resolved = environment.machines.machineId(forSyncKey: machineId) {
                        signInRequest = HarnessSignInRequest(
                            serverId: resolved, harnessId: entry.harnessId)
                    }
                }
                .font(.footnote)
            }
        }
    }

    private func harnessRow(_ harness: ServerHarness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                if let auth = harness.auth,
                    auth.state != "authenticated", auth.state != "notRequired"
                {
                    Button("Sign in to use") {
                        signInRequest = HarnessSignInRequest(
                            serverId: serverId,
                            harnessId: harness.id,
                            initialHarness: harness
                        )
                    }
                    .font(.footnote)
                }
            }
            Spacer()
            Toggle(
                "Enable \(harness.name)",
                isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setHarnessEnabled(
                                id: harness.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func load() async {
        do {
            harnesses = try await client.listHarnesses()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
