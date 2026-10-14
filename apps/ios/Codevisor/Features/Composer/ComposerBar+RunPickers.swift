import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
  var runTargetControls: some View {
    let machine = environment.machines.machine(for: controller.project.serverId)
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
      project: liveProject,
      wantsNewWorktree: controller.wantsNewWorktree,
      onMachine: selectTargetMachine,
      onProject: { selectTargetProject($0) },
      onLocation: selectRunLocation,
      onManageMachines: { showsMachineSettings = true },
      onManageProject: { managedProject = liveProject },
      onProjectDeleted: projectDeleted
    )
    .padding(.vertical, -6)
    .composerGlassSurface(
      shape: cardStyle.shape, id: .newChatConfiguration, in: glassNamespace
    )
    .padding(.vertical, 6)
    .disabled(controller.isSubmitting || controller.hasAcceptedFirstSend)
  }

  private var liveProject: Project {
    environment.projectList.fleetActiveProjects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

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
        projectId: project.id,
        createsWorktree: effectiveWorktree
      )
    }
    Task {
      guard revision == runTargetSelectionRevision else { return }
      controller.wantsNewWorktree = effectiveWorktree
      if project.serverId != controller.project.serverId {
        await controller.retarget(
          to: project,
          serverClient: environment.machines.client(for: project.serverId)
        )
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
    guard project.serverId != controller.project.serverId || project.id != controller.project.id
    else { return }
    let prefersWorktree = wantsWorktree ?? environment.prefersNewWorktree(for: project)
    applyRunTarget(project, wantsWorktree: prefersWorktree)
  }

  private func selectRunLocation(_ newWorktree: Bool) {
    guard liveProject.isGitRepository else { return }
    environment.rememberRunLocation(newWorktree: newWorktree, for: liveProject)
    controller.wantsNewWorktree = newWorktree
  }

  func projectDeleted(_ group: ProjectGroup) {
    guard group.contains(controller.project) else { return }
    selectTargetProject(.runTargetPlaceholder(serverId: controller.project.serverId))
  }
}
