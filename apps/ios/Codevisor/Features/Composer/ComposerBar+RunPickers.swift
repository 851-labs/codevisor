import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
    /// Projects offered by the picker (scratch backing projects, when a
    /// server has any, are internal and never listed).
    private var pickerProjects: [Project] {
        environment.projectList.activeProjects.filter { !$0.isScratch }
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
            projectChip
            if liveProject.isGitRepository {
                Divider()
                    .frame(height: 14)
                    .accessibilityHidden(true)
                runLocationChip
            }
        }
    }

    private var projectChip: some View {
        Menu {
            ForEach(pickerProjects) { project in
                Button {
                    selectTargetProject(project)
                } label: {
                    menuRow(
                        project.name,
                        systemImage: EntitySystemSymbol.project,
                        isSelected: controller.project.id == project.id
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
            await controller.selectProject(project)
            controller.wantsNewWorktree = prefersWorktree
        }
        // Re-probe git capability so the run-location chip tracks fresh data.
        Task { await environment.projectList.refreshFromServer() }
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
