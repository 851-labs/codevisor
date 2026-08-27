import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Harnesses

/// The Harnesses screen: a machine list that pushes each machine's
/// harnesses — installs and sign-ins are genuinely per machine.
struct HarnessesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            MachineListSection(badge: badge) { machine in
                HarnessMachineRows(machine: machine)
            }
        }
        .navigationTitle("Harnesses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        guard let key = environment.machines.syncKey(forMachineId: machine.id),
            let rows = HarnessFleet.readiness(environment.configSync)[key]
        else { return .syncing }
        if rows.contains(where: { $0.state == "signInRequired" }) {
            return .attention("Sign in required")
        }
        return .synced
    }
}

/// One machine's harnesses: sign-in, enable, and what's not installed yet.
private struct HarnessMachineRows: View {
    @Environment(AppEnvironment.self) private var environment
    let machine: CodevisorMachine
    @State private var harnesses: [ServerHarness] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var signInRequest: HarnessSignInRequest?

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: machine.id)
    }

    private var installed: [ServerHarness] {
        harnesses.filter { $0.readiness.state != "notInstalled" }
    }

    private var notInstalled: [ServerHarness] {
        harnesses.filter { $0.readiness.state == "notInstalled" }
    }

    var body: some View {
        Group {
            if isLoading, harnesses.isEmpty {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                ForEach(installed, id: \.id) { harness in
                    harnessRow(harness)
                }
                if !notInstalled.isEmpty {
                    DisclosureGroup("Not installed (\(notInstalled.count))") {
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
                    .font(.footnote)
                }
            }
        }
        .task(id: machine.id) {
            isLoading = true
            await load()
        }
        .harnessSignInSheet(request: $signInRequest)
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
                            serverId: machine.id,
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
