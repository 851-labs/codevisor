import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
  /// The live project record. The controller holds a snapshot from when
  /// the project was picked; the server's git probe lands on the list
  /// afterwards, and the chip must follow the probed value.
  private var liveProject: Project {
    environment.projectList.projects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

  /// ONE chip for the whole run target: the run-location icon and the
  /// project name ("No Project" for a chat that will run in its own
  /// folder). Tapping opens the stepped machine → project → run-location
  /// sheet.
  var runTargetChips: some View {
    // A retained scratch-backed draft (first send failed, retry pending)
    // still reads as "No Project".
    let isPlaceholder = controller.project.isRunTargetPlaceholder || controller.project.isScratch
    return Button {
      showsRunTargetPicker = true
    } label: {
      HStack(spacing: 4) {
        Image(
          systemName: isPlaceholder
            ? EntitySystemSymbol.projectList
            : (controller.wantsNewWorktree ? "arrow.triangle.branch" : "folder.fill")
        )
        .font(.caption)
        Text(isPlaceholder ? "No Project" : controller.project.name)
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
        ? "No project"
        : "\(controller.project.name), \(controller.wantsNewWorktree ? "new worktree" : "project directory")"
    )
  }

  /// Applies a picker choice: re-points the draft (across machines when
  /// needed) and fixes the run location, remembering both per machine.
  func applyRunTarget(_ project: Project, wantsWorktree: Bool) {
    // "No project" is remembered as the placeholder id, so the next draft
    // on this machine starts the same way.
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
      guard controller.project.serverId == project.serverId,
        controller.project.id == project.id
      else { return }
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

  /// Archiving the draft's project leaves the draft with no project rather
  /// than guessing another one.
  func archiveManagedProject(_ project: Project) {
    controller.project.isArchived = true
    environment.projectList.archive(project)
    selectTargetProject(.runTargetPlaceholder(serverId: project.serverId))
  }
}
