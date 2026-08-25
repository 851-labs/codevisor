import CodevisorCore
import CodevisorUI
import SwiftUI

extension NewChatView {
    /// The pickers only exist on the standalone page: they decide the
    /// workspace's one working directory, which is fixed the moment the
    /// first message creates it. Drafts inside an existing workspace always
    /// run in that workspace's directory.
    var showsRunPickers: Bool { paneDraftId == nil }

    /// Every machine's projects, most recently used first (scratch backing
    /// projects, when a server has any, are internal and never listed).
    private var pickerProjects: [Project] {
        environment.projectList.fleetActiveProjectsByWorkspaceRecency(
            environment.workspaces.loadAll()
        )
        .filter { !$0.isScratch }
    }

    /// The machine picker shows only when there is a choice to make.
    var showsMachinePicker: Bool { environment.machines.allMachines.count > 1 }

    /// Projects offered by the project picker: the picked machine's only.
    /// The machine chip to its left is what changes machines.
    func machineScopedProjects(for controller: SessionController) -> [Project] {
        pickerProjects.filter { $0.serverId == controller.project.serverId }
    }

    /// The live project record. The controller holds a snapshot from when
    /// the project was picked; the server's git probe lands on the list
    /// afterwards, and the worktree picker must follow the probed value.
    func liveProject(for controller: SessionController) -> Project {
        environment.projectList.projects.first {
            $0.serverId == controller.project.serverId && $0.id == controller.project.id
        } ?? controller.project
    }

    /// Choose the machine this chat runs on. Picking one re-points the draft
    /// at that machine's remembered (or most recent) project; the project
    /// picker then lists that machine's projects.
    func machinePicker(_ controller: SessionController) -> some View {
        let selectedServerId = controller.project.serverId
        let selectedMachine = environment.machines.machine(for: selectedServerId)
        return Menu {
            // Toggle for the native selected checkmark; MenuSymbolIcon
            // because AppKit menus drop plain SF Symbol images.
            ForEach(environment.machines.allMachines) { machine in
                Toggle(
                    isOn: Binding(
                        get: { machine.id == selectedServerId },
                        set: { isOn in
                            guard isOn else { return }
                            selectTargetMachine(machine, controller: controller)
                        }
                    )
                ) {
                    Label {
                        Text(machine.name)
                    } icon: {
                        MenuSymbolIcon(systemName: EntitySystemSymbol.machine(machine))
                    }
                }
                .disabled(
                    machine.id != selectedServerId
                        && !pickerProjects.contains { $0.serverId == machine.id }
                )
            }
        } label: {
            PickerChip(text: selectedMachine?.name ?? "Machine") {
                Image(
                    systemName: selectedMachine.map(EntitySystemSymbol.machine)
                        ?? EntitySystemSymbol.machine(.local)
                )
                .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which machine this chat runs on")
        .accessibilityLabel("Machine")
        .accessibilityValue(selectedMachine?.name ?? "Machine")
    }

    /// Choose the project the chat (and the workspace created around it on
    /// first send) will work in.
    func projectPicker(_ controller: SessionController) -> some View {
        let selected = controller.project
        return Menu {
            // Toggle for the native selected checkmark; MenuSymbolIcon
            // because AppKit menus drop plain SF Symbol images.
            ForEach(machineScopedProjects(for: controller)) { project in
                Toggle(
                    isOn: Binding(
                        get: {
                            selected.serverId == project.serverId
                                && selected.id == project.id
                        },
                        set: { isOn in
                            guard isOn else { return }
                            selectTargetProject(project, controller: controller)
                        }
                    )
                ) {
                    Label {
                        Text(project.name)
                    } icon: {
                        MenuSymbolIcon(systemName: EntitySystemSymbol.project)
                    }
                }
            }
            Divider()
            Button {
                addProjectFlow.begin()
            } label: {
                Label {
                    Text("New project…")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.badge.plus")
                }
            }
        } label: {
            PickerChip(text: selected.name) {
                Image(systemName: EntitySystemSymbol.project)
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose where this chat works")
        .accessibilityLabel("Project")
        .accessibilityValue(selected.name)
    }

    /// "Project directory" vs "New worktree" for where the chat (and its
    /// workspace) runs. Only rendered for git projects; the worktree itself
    /// is created on the first send.
    func runLocationPicker(_ controller: SessionController) -> some View {
        let newWorktree = controller.wantsNewWorktree
        return Menu {
            Toggle(
                isOn: Binding(
                    get: { !newWorktree },
                    set: { isOn in
                        guard isOn else { return }
                        selectRunLocation(newWorktree: false, controller: controller)
                    }
                )
            ) {
                Label {
                    Text("Project directory")
                } icon: {
                    MenuSymbolIcon(systemName: "folder.fill")
                }
            }
            Toggle(
                isOn: Binding(
                    get: { newWorktree },
                    set: { isOn in
                        guard isOn else { return }
                        selectRunLocation(newWorktree: true, controller: controller)
                    }
                )
            ) {
                Label {
                    Text("New worktree")
                } icon: {
                    MenuSymbolIcon(systemName: "arrow.triangle.branch")
                }
            }
            Divider()
            Button {
                managedProject = liveProject(for: controller)
            } label: {
                Label {
                    Text("Manage Project…")
                } icon: {
                    MenuSymbolIcon(systemName: "gearshape")
                }
            }
        } label: {
            PickerChip(text: newWorktree ? "New worktree" : "Project directory") {
                Image(systemName: newWorktree ? "arrow.triangle.branch" : "folder.fill")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where this chat's commands run")
        .accessibilityLabel("Run location")
        .accessibilityValue(newWorktree ? "New worktree" : "Project directory")
    }

    /// Re-points the draft at another machine: its remembered project when
    /// it still exists, else its most recently used one.
    func selectTargetMachine(_ machine: CodevisorMachine, controller: SessionController) {
        guard machine.id != controller.project.serverId else { return }
        let scoped = pickerProjects.filter { $0.serverId == machine.id }
        let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
        guard let project = scoped.first(where: { $0.id == remembered }) ?? scoped.first
        else { return }
        selectTargetProject(project, controller: controller)
    }

    /// A picked project carries the machine's remembered worktree preference
    /// (worktrees only make sense for git projects).
    func selectTargetProject(_ project: Project, controller: SessionController) {
        selectedProjectId = project.id
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
        // run-location picker appears/disappears with fresh data.
        Task {
            await environment.projectList.refreshFromServer(
                serverId: project.serverId,
                client: environment.machines.client(for: project.serverId)
            )
        }
    }

    func archiveManagedProject(_ project: Project, controller: SessionController?) {
        environment.projectList.archive(project)
        guard let controller, let replacement = pickerProjects.first else { return }
        selectTargetProject(replacement, controller: controller)
    }

    private func selectRunLocation(newWorktree: Bool, controller: SessionController) {
        environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: controller.project.serverId,
            createsWorktree: newWorktree
        )
        controller.wantsNewWorktree = newWorktree
    }
}
