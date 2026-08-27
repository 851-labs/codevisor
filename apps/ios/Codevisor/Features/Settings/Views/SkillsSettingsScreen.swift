import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Skills

/// The Skills screen: a machine list that pushes each machine's skill
/// store; the fleet ferries skill content between machines.
struct SkillsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// Each machine's scanned skill directory names, fetched per machine so
    /// the badge can compare against the fleet's synced skill set instead of
    /// guessing from reachability.
    @State private var scannedSkillsByMachine: [String: Set<String>] = [:]

    var body: some View {
        List {
            MachineListSection(badge: badge) { machine in
                SkillMachineRows(machine: machine)
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.machines.allMachines.map(\.id)) { await scanAllMachines() }
    }

    /// The badge tells the truth per machine: a machine missing skills the
    /// fleet carries is still syncing, not "Synced".
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

/// One machine's global skills, with per-machine sync and removal.
private struct SkillMachineRows: View {
    @Environment(AppEnvironment.self) private var environment
    let machine: CodevisorMachine
    @State private var scan: ServerSkillsScan?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: machine.id)
    }

    var body: some View {
        Group {
            if isLoading, scan == nil {
                HStack {
                    Spacer(); ProgressView(); Spacer()
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let scan {
                if scan.global.isEmpty {
                    Text("No skills on this machine yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scan.global, id: \.id) { skill in
                        skillRow(skill)
                    }
                }
                Button {
                    Task {
                        self.scan = try? await client.syncSkills(directoryNames: nil)
                    }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
        .task(id: machine.id) {
            isLoading = true
            await load()
        }
    }

    private func skillRow(_ skill: ServerGlobalSkill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
            if let description = skill.description, !description.isEmpty {
                // No detail screen exists, so the row is the only place this
                // description can be read — let it wrap fully.
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    scan = try? await client.removeSkill(directoryName: skill.directoryName)
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
    }

    private func load() async {
        do {
            scan = try await client.listSkills()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
