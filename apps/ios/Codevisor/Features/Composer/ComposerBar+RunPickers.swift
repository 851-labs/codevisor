import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
    /// Every machine's projects, most recently used first (scratch backing
    /// projects, when a server has any, are internal and never listed).
    private var pickerProjects: [Project] {
        environment.projectList.fleetActiveProjectsByWorkspaceRecency(
            environment.workspaces.loadAll()
        )
        .filter { !$0.isScratch }
    }

    /// The machine chip shows only when there is a choice to make.
    private var showsMachineChip: Bool { environment.machines.allMachines.count > 1 }

    /// Projects offered by the project chip: the picked machine's only. The
    /// machine chip to its left is what changes machines.
    private var machineScopedProjects: [Project] {
        pickerProjects.filter { $0.serverId == controller.project.serverId }
    }

    /// The live project record. The controller holds a snapshot from when
    /// the project was picked; the server's git probe lands on the list
    /// afterwards, and the worktree chip must follow the probed value.
    private var liveProject: Project {
        environment.projectList.projects.first {
            $0.serverId == controller.project.serverId && $0.id == controller.project.id
        } ?? controller.project
    }

    var runTargetChips: some View {
        HStack(spacing: 10) {
            if showsMachineChip {
                machineChip
                Divider()
                    .frame(height: 14)
                    .accessibilityHidden(true)
            }
            projectChip
            if liveProject.isGitRepository {
                Divider()
                    .frame(height: 14)
                    .accessibilityHidden(true)
                runLocationChip
            }
        }
    }

    /// Choose the machine this chat runs on. Picking one re-points the draft
    /// at that machine's remembered (or most recent) project; the project
    /// chip then lists that machine's projects.
    private var machineChip: some View {
        let selectedServerId = controller.project.serverId
        let selectedMachine = environment.machines.machine(for: selectedServerId)
        return Menu {
            ForEach(environment.machines.allMachines) { machine in
                Button {
                    selectTargetMachine(machine)
                } label: {
                    menuRow(
                        machine.name,
                        systemImage: EntitySystemSymbol.machine(machine),
                        isSelected: machine.id == selectedServerId
                    )
                }
                .disabled(
                    machine.id != selectedServerId
                        && !pickerProjects.contains { $0.serverId == machine.id }
                )
            }
        } label: {
            chipLabel(
                selectedMachine?.name ?? "Machine",
                systemImage: selectedMachine.map(EntitySystemSymbol.machine)
                    ?? EntitySystemSymbol.machine(.local)
            )
        }
        .accessibilityLabel("Machine")
        .accessibilityValue(selectedMachine?.name ?? "Machine")
    }

    private var projectChip: some View {
        Menu {
            ForEach(machineScopedProjects) { project in
                Button {
                    selectTargetProject(project)
                } label: {
                    menuRow(
                        project.name,
                        systemImage: EntitySystemSymbol.project,
                        isSelected: controller.project.serverId == project.serverId
                            && controller.project.id == project.id
                    )
                }
            }
            Divider()
            Button {
                isAddingProject = true
            } label: {
                Label("New Project…", systemImage: "folder.badge.plus")
            }
        } label: {
            chipLabel(controller.project.name, systemImage: EntitySystemSymbol.project)
        }
        .accessibilityLabel("Project")
        .accessibilityValue(controller.project.name)
    }

    private var runLocationChip: some View {
        let newWorktree = controller.wantsNewWorktree
        return Menu {
            Button {
                selectRunLocation(newWorktree: false)
            } label: {
                menuRow("Project Directory", systemImage: "folder.fill", isSelected: !newWorktree)
            }
            Button {
                selectRunLocation(newWorktree: true)
            } label: {
                menuRow("New Worktree", systemImage: "arrow.triangle.branch", isSelected: newWorktree)
            }
            Divider()
            Button {
                managedProject = liveProject
            } label: {
                Label("Manage Project…", systemImage: "gearshape")
            }
        } label: {
            chipLabel(
                newWorktree ? "New Worktree" : "Project Directory",
                systemImage: newWorktree ? "arrow.triangle.branch" : "folder.fill"
            )
        }
        .accessibilityLabel("Run location")
        .accessibilityValue(newWorktree ? "New Worktree" : "Project Directory")
    }

    /// Re-points the draft at another machine: its remembered project when
    /// it still exists, else its most recently used one.
    private func selectTargetMachine(_ machine: CodevisorMachine) {
        guard machine.id != controller.project.serverId else { return }
        let scoped = pickerProjects.filter { $0.serverId == machine.id }
        let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
        guard let project = scoped.first(where: { $0.id == remembered }) ?? scoped.first
        else { return }
        selectTargetProject(project)
    }

    /// A picked project carries the machine's remembered worktree preference
    /// (worktrees only make sense for git projects).
    func selectTargetProject(_ project: Project) {
        environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: project.serverId,
            projectId: project.id
        )
        let prefersWorktree =
            project.isGitRepository
            && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
                forServer: project.serverId
            )
        Task {
            if project.serverId != controller.project.serverId {
                // Another machine's project: the draft re-points there in
                // place — client, catalog and all. The app's selected
                // machine follows at first send, not now.
                await controller.retarget(
                    to: project,
                    serverClient: environment.machines.client(for: project.serverId)
                )
                await environment.refreshHarnessLifecycle(for: project.serverId)
            } else {
                await controller.selectProject(project)
            }
            controller.wantsNewWorktree = prefersWorktree
        }
        // Re-probe git capability on the picked project's machine so the
        // run-location chip tracks fresh data.
        Task {
            await environment.projectList.refreshFromServer(
                serverId: project.serverId,
                client: environment.machines.client(for: project.serverId)
            )
        }
    }

    func archiveManagedProject(_ project: Project) {
        controller.project.isArchived = true
        environment.projectList.archive(project)
        guard let replacement = pickerProjects.first else { return }
        selectTargetProject(replacement)
    }

    private func selectRunLocation(newWorktree: Bool) {
        environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: controller.project.serverId,
            createsWorktree: newWorktree
        )
        controller.wantsNewWorktree = newWorktree
    }

    private func chipLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menuRow(_ title: String, systemImage: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}
