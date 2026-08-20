import CodevisorCore
import CodevisorUI
import SwiftUI

extension NewChatView {
    /// The pickers only exist on the standalone page: they decide the
    /// workspace's one working directory, which is fixed the moment the
    /// first message creates it. Drafts inside an existing workspace always
    /// run in that workspace's directory.
    var showsRunPickers: Bool { paneDraftId == nil }

    /// Projects offered by the picker (scratch backing projects, when a
    /// server has any, are internal and never listed).
    private var pickerProjects: [Project] {
        projects.filter { !$0.isScratch }
    }

    /// The live project record. The controller holds a snapshot from when
    /// the project was picked; the server's git probe lands on the list
    /// afterwards, and the worktree picker must follow the probed value.
    func liveProject(for controller: SessionController) -> Project {
        projects.first { $0.id == controller.project.id } ?? controller.project
    }

    /// Choose the project the chat (and the workspace created around it on
    /// first send) will work in.
    func projectPicker(_ controller: SessionController) -> some View {
        let selected = controller.project
        return Menu {
            // Toggle for the native selected checkmark; MenuSymbolIcon
            // because AppKit menus drop plain SF Symbol images.
            ForEach(pickerProjects) { project in
                Toggle(
                    isOn: Binding(
                        get: { selected.id == project.id },
                        set: { isOn in
                            guard isOn else { return }
                            selectTargetProject(project, controller: controller)
                            // Re-probe git capability so the run-location picker
                            // appears/disappears with fresh data.
                            Task { await environment.projectList.refreshFromServer() }
                        }
                    )
                ) {
                    Label {
                        Text(project.name)
                    } icon: {
                        MenuSymbolIcon(systemName: FilledSymbol.preferred(project.symbolName))
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
                Image(systemName: FilledSymbol.preferred(selected.symbolName))
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
            await controller.selectProject(project)
            controller.wantsNewWorktree = prefersWorktree
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
