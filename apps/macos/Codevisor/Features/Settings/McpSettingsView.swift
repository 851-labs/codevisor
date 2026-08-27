import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

/// The MCP pane: a native machine list — sync badge on each row — that
/// pushes each machine's full MCP picture, plus one fleet-level Add.
struct McpSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var showingAdd = false
    @State private var addError: String?

    var body: some View {
        Form {
            MachineListSection(pane: .mcps, badge: badge) { machine in
                McpMachinePane(machine: machine)
            }
            // A single-machine fleet renders that machine's own Add inline;
            // the fleet-level action only earns its place above a list.
            if environment.machines.allMachines.count > 1 {
                Section {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add MCP Server…", systemImage: "plus")
                    }
                    .settingsActionTint(theme)
                    if let addError {
                        Label(addError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .background {
            if !theme.isSystem { theme.windowBackground }
        }
        .sheet(isPresented: $showingAdd) {
            McpServerEditorSheet(initialServer: nil) { values in
                // Added through the local machine; the definition syncs out.
                let client = environment.machines.client(for: CodevisorMachine.local.id)
                let created = try await client.createMcpServer(values.createBody)
                if created.authType == "oauth" {
                    Task {
                        do {
                            let flow = try await client.startMcpOAuth(id: created.id)
                            if let url = URL(string: flow.authorizationUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        } catch {
                            addError = ErrorReporter.userFacingMessage(for: error)
                        }
                    }
                }
            }
        }
    }

    /// The disclosure-row badge: unreachable machines need attention, a
    /// machine with no readiness entry yet is still converging, blocked
    /// servers need attention, connecting ones are syncing.
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        guard let key = environment.machines.syncKey(forMachineId: machine.id),
            let rows = McpFleet.readiness(environment.configSync)[key]
        else { return .syncing }
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "connecting" }) { return .syncing }
        return .synced
    }
}

#Preview("MCP Settings") {
    McpSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
