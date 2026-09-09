import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
  var runTargetControls: some View {
    let machine = environment.machines.machine(for: controller.project.serverId)
    let isPlaceholder = controller.project.isRunTargetPlaceholder || controller.project.isScratch
    return ComposerRunTargetBar(
      machineName: environment.machines.allMachines.count > 1 ? (machine?.name ?? "Machine") : nil,
      machineSymbol: machine.map(EntitySystemSymbol.machine) ?? EntitySystemSymbol.machine(.local),
      machines: environment.machines.allMachines,
      selectedServerId: controller.project.serverId,
      readyMachineIds: Set(
        environment.machines.allMachines
          .filter { environment.machines.availability(for: $0.id) == .ready }
          .map(\.id)
      ),
      projectName: isPlaceholder ? "No project" : liveProject.name,
      isPlaceholder: isPlaceholder,
      isGitRepository: !isPlaceholder && liveProject.isGitRepository,
      wantsNewWorktree: controller.wantsNewWorktree,
      onMachine: selectTargetMachine,
      onProject: { showsProjectPicker = true },
      onLocation: selectRunLocation,
      onManageMachines: { showsMachineSettings = true },
      onManageProject: { managedProject = liveProject }
    )
    // Keep 44-point controls while drawing a slimmer pill behind them.
    .padding(.vertical, -6)
    .composerGlassSurface(
      cornerRadius: 16, id: .newChatConfiguration, in: glassNamespace
    )
    .padding(.vertical, 6)
    .disabled(controller.isSubmitting || controller.hasAcceptedFirstSend)
  }

  /// Follow the server's current git probe, rather than the draft's snapshot.
  private var liveProject: Project {
    environment.projectList.fleetActiveProjects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

  /// Keep the linked checkout and location when possible, matching macOS.
  /// Otherwise restore the destination's remembered project, or No project.
  func selectTargetMachine(_ machine: CodevisorMachine) {
    let current = controller.project
    guard machine.id != current.serverId,
      environment.machines.availability(for: machine.id) == .ready
    else { return }
    if let linked = environment.projectList.fleetProjectGroup(containing: current)?
      .member(on: machine.id)
    {
      selectTargetProject(linked, wantsWorktree: controller.wantsNewWorktree)
      return
    }
    let remembered = environment.composerDefaults.lastProjectId(forServer: machine.id)
    let project = environment.projectList.fleetActiveProjects.first {
      $0.serverId == machine.id && $0.id == remembered && !$0.isScratch
    }
    if !current.isRunTargetPlaceholder, !current.isScratch, let project {
      selectTargetProject(project)
    } else {
      selectTargetProject(.runTargetPlaceholder(serverId: machine.id))
    }
  }

  /// Re-points the draft in place, keeping its text and staged attachments.
  func applyRunTarget(_ project: Project, wantsWorktree: Bool) {
    runTargetSelectionRevision &+= 1
    let revision = runTargetSelectionRevision
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: project.serverId,
      projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
    )
    let effectiveWorktree = project.isGitRepository && wantsWorktree
    if project.isGitRepository {
      environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
        serverId: project.serverId,
        createsWorktree: effectiveWorktree
      )
    }
    Task {
      guard revision == runTargetSelectionRevision else { return }
      // Set this before awaiting preparation so the independent location
      // picker reflects the new target immediately and remains editable.
      controller.wantsNewWorktree = effectiveWorktree
      if project.serverId != controller.project.serverId {
        await controller.retarget(
          to: project,
          serverClient: environment.machines.client(for: project.serverId)
        )
        await environment.refreshHarnessLifecycle(for: project.serverId)
      } else {
        await controller.selectProject(project)
      }
    }
    Task {
      await environment.projectList.refreshFromServer(
        serverId: project.serverId,
        client: environment.machines.client(for: project.serverId)
      )
    }
  }

  func selectTargetProject(_ project: Project, wantsWorktree: Bool? = nil) {
    // Selecting the checked row should preserve the draft's own location.
    guard project.serverId != controller.project.serverId || project.id != controller.project.id
    else { return }
    let prefersWorktree =
      wantsWorktree
      ?? environment.composerDefaults.prefersWorktreeForNewWorkspaces(forServer: project.serverId)
    applyRunTarget(project, wantsWorktree: prefersWorktree)
  }

  private func selectRunLocation(_ newWorktree: Bool) {
    guard liveProject.isGitRepository else { return }
    environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
      serverId: controller.project.serverId,
      createsWorktree: newWorktree
    )
    controller.wantsNewWorktree = newWorktree
  }

  func archiveManagedProject(_ project: Project) {
    controller.project.isArchived = true
    environment.projectList.archive(project)
    selectTargetProject(.runTargetPlaceholder(serverId: project.serverId))
  }
}
