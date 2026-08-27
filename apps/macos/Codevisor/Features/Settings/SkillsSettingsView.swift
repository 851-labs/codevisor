import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Skills pane: a native machine list that pushes each machine's skill
/// store — the fleet ferries skill content between machines, and the badge
/// reports how in-sync each machine actually is.
struct SkillsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    /// Each machine's scanned skill directory names, fetched per machine so
    /// the badge can compare against the fleet's synced skill set instead of
    /// guessing from reachability.
    @State private var scannedSkillsByMachine: [String: Set<String>] = [:]

    var body: some View {
        Form {
            MachineListSection(pane: .skills, badge: badge) { machine in
                SkillMachinePane(machine: machine)
            }
        }
        .settingsPaneFormStyle(theme)
        .background {
            if !theme.isSystem { theme.windowBackground }
        }
        .task(id: environment.machines.allMachines.map(\.id)) { await scanAllMachines() }
    }

    /// The badge tells the truth per machine: a machine missing skills the
    /// fleet carries is still syncing, not "Synced". The fleet's skill set
    /// is the synced "skills" namespace (directory name → tree hash).
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        let fleetSkills = Set(
            environment.configSync.entries(namespace: "skills")
                .filter { $0.deleted != true }
                .map(\.key)
        )
        guard let scanned = scannedSkillsByMachine[machine.id] else { return .syncing }
        return fleetSkills.isSubset(of: scanned) ? .synced : .syncing
    }

    private func scanAllMachines() async {
        await withTaskGroup(of: (String, Set<String>?).self) { group in
            for machine in environment.machines.allMachines {
                let client = environment.machines.client(for: machine.id)
                group.addTask { @MainActor in
                    let scan = try? await client.listSkills()
                    return (machine.id, scan.map { Set($0.global.map(\.directoryName)) })
                }
            }
            for await (machineId, skills) in group {
                if let skills { scannedSkillsByMachine[machineId] = skills }
            }
        }
    }
}

#Preview("Skills") {
    SkillsSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
