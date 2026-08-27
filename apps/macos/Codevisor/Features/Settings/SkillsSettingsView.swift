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

    @State private var showingCreate = false
    @State private var showingRemoteImport = false
    @State private var actionError: String?

    /// Fleet-level skill creation lands on the local machine; the ferry
    /// carries the content everywhere else.
    private var localClient: any CodevisorServerClienting {
        environment.machines.client(for: CodevisorMachine.local.id)
    }

    var body: some View {
        Form {
            MachineListSection(pane: .skills, badge: badge) { machine in
                SkillMachinePane(machine: machine)
            }
            Section {
                HStack(spacing: 10) {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New Skill…", systemImage: "plus")
                    }
                    .settingsActionTint(theme)
                    Button("Import Skills…") { showingRemoteImport = true }
                        .settingsActionTint(theme)
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsPaneFormStyle(theme)
        .background {
            if !theme.isSystem { theme.windowBackground }
        }
        .task(id: environment.machines.allMachines.map(\.id)) { await scanAllMachines() }
        .sheet(isPresented: $showingCreate) {
            SkillCreateSheet { name, description, pasted in
                do {
                    _ = try await localClient.createSkill(
                        name: name,
                        description: description,
                        content: pasted
                    )
                    actionError = nil
                } catch {
                    actionError = ErrorReporter.userFacingMessage(for: error)
                    throw error
                }
            }
        }
        .sheet(isPresented: $showingRemoteImport) {
            SkillRemoteImportSheet(
                discover: { source in
                    try await localClient.discoverRemoteSkills(source: source)
                },
                onImport: { source, skillNames in
                    do {
                        _ = try await localClient.importRemoteSkill(
                            source: source,
                            skillNames: skillNames
                        )
                        actionError = nil
                    } catch {
                        actionError = ErrorReporter.userFacingMessage(for: error)
                        throw error
                    }
                }
            )
        }
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
