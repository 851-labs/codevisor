import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Skills

/// The Skills screen: the machines ARE the page. One disclosure per
/// machine with that machine's skill store inside; the fleet ferries
/// skill content between machines.
struct SkillsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            MachineConfigSections(badge: badge) { machine in
                SkillMachineRows(machine: machine)
            }
            Section {
            } footer: {
                Text("Skills sync across your fleet — a skill added here appears on every machine.")
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Skills have no readiness plane — their single source of truth is the
    /// synced tree hash, so the badge derives from reachability alone.
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        return .synced
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
