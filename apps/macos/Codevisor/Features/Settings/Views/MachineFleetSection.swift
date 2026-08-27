import CodevisorCore
import CodevisorUI
import SwiftUI

/// How a machine's slice of a config plane is doing, shown on its
/// disclosure row: converging, settled, or waiting on the user.
enum MachineSyncBadge {
    case syncing
    case synced
    case attention(String)

    @ViewBuilder
    var view: some View {
        switch self {
        case .syncing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
            .foregroundStyle(.secondary)
        case .synced:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Synced")
                    .foregroundStyle(.secondary)
            }
        case .attention(let label):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(label)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The one shape every settings pane uses for per-machine state (Phase
/// 27): a disclosure per machine — sync badge on the row, that machine's
/// items inside. Hidden for single-machine fleets.
struct MachineFleetSection<Row: Identifiable, RowView: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let rowsByMachine: [String: [Row]]
    let badge: (String, [Row]) -> MachineSyncBadge
    @ViewBuilder let row: (String, Row) -> RowView
    @State private var expandedMachines: Set<String> = []

    var body: some View {
        if environment.machines.allMachines.count > 1, !rowsByMachine.isEmpty {
            Section {
                ForEach(rowsByMachine.keys.sorted(), id: \.self) { machineId in
                    let rows = rowsByMachine[machineId] ?? []
                    SettingsDisclosureRow(isExpanded: expansionBinding(machineId)) {
                        HStack {
                            Text(machineName(machineId))
                            Spacer(minLength: 12)
                            badge(machineId, rows).view
                                .font(.callout)
                        }
                    } content: {
                        ForEach(rows) { item in
                            row(machineId, item)
                                .padding(.leading, 17)
                                .padding(.top, 6)
                        }
                    }
                }
            } header: {
                Text("On Your Machines")
            }
        }
    }

    private func machineName(_ syncKey: String) -> String {
        environment.machines.fleetName(forSyncKey: syncKey)
    }

    private func expansionBinding(_ machineId: String) -> Binding<Bool> {
        Binding(
            get: { expandedMachines.contains(machineId) },
            set: { expanded in
                if expanded {
                    expandedMachines.insert(machineId)
                } else {
                    expandedMachines.remove(machineId)
                }
            }
        )
    }
}
