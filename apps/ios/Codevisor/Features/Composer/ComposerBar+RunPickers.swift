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

    /// The live project record. The controller holds a snapshot from when
    /// the project was picked; the server's git probe lands on the list
    /// afterwards, and the chip must follow the probed value.
    private var liveProject: Project {
        environment.projectList.projects.first {
            $0.serverId == controller.project.serverId && $0.id == controller.project.id
        } ?? controller.project
    }

    /// ONE chip for the whole run target: the run-location icon and the
    /// project name. Tapping opens the stepped machine → project →
    /// run-location sheet.
    var runTargetChips: some View {
        let isPlaceholder = controller.project.isRunTargetPlaceholder
        return Button {
            showsRunTargetPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(
                    systemName: controller.wantsNewWorktree && !isPlaceholder
                        ? "arrow.triangle.branch" : "folder.fill"
                )
                .font(.caption)
                Text(isPlaceholder ? "Select a project" : controller.project.name)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            if !isPlaceholder {
                Button {
                    managedProject = liveProject
                } label: {
                    Label("Manage Project…", systemImage: "gearshape")
                }
            }
        }
        .accessibilityLabel("Run target")
        .accessibilityValue(
            isPlaceholder
                ? "No project selected"
                : "\(controller.project.name), \(controller.wantsNewWorktree ? "new worktree" : "project directory")"
        )
    }

    /// Applies a picker choice: re-points the draft (across machines when
    /// needed) and fixes the run location, remembering both per machine.
    func applyRunTarget(_ project: Project, wantsWorktree: Bool) {
        environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: project.serverId,
            projectId: project.id
        )
        let effectiveWorktree = project.isGitRepository && wantsWorktree
        if project.isGitRepository {
            environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
                serverId: project.serverId,
                createsWorktree: effectiveWorktree
            )
        }
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
            controller.wantsNewWorktree = effectiveWorktree
        }
        // Re-probe git capability on the picked project's machine so the
        // chip's icon tracks fresh data.
        Task {
            await environment.projectList.refreshFromServer(
                serverId: project.serverId,
                client: environment.machines.client(for: project.serverId)
            )
        }
    }

    /// A picked project carries the machine's remembered worktree preference
    /// (worktrees only make sense for git projects).
    func selectTargetProject(_ project: Project) {
        let prefersWorktree =
            project.isGitRepository
            && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
                forServer: project.serverId
            )
        applyRunTarget(project, wantsWorktree: prefersWorktree)
    }

    func archiveManagedProject(_ project: Project) {
        controller.project.isArchived = true
        environment.projectList.archive(project)
        guard let replacement = pickerProjects.first else { return }
        selectTargetProject(replacement)
    }
}
