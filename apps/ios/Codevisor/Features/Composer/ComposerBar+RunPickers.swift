import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
  var runTargetControls: some View {
    withProjectSetup(runTargetBar)
  }

  private var runTargetBar: some View {
    let machine = environment.machines.machine(for: controller.project.serverId)
    let sandbox = controller.sandboxTarget
    return ComposerRunTargetBar(
      machineName: sandbox?.pickerTitle ?? machine?.name ?? "Machine",
      hasOtherMachines: environment.machines.chatMachines.count > 1,
      machineIcon: sandbox.map { CodevisorSymbol.sandboxVendor($0.vendorId) }
        ?? Image(systemName: (machine?.icon ?? .fallback).systemImage),
      machines: environment.machines.chatMachines,
      selectedServerId: controller.project.serverId,
      readyMachineIds: Set(
        environment.machines.allMachines
          .filter { environment.machines.availability(for: $0.id) == .ready }
          .map(\.id)
      ),
      project: liveProject,
      pendingSetupGroup: controller.project.isRunTargetPlaceholder ? pendingSetupGroup : nil,
      wantsNewWorktree: controller.wantsNewWorktree,
      onMachine: selectTargetMachine,
      onProject: { selectTargetProject($0) },
      onSetUpProject: selectSetUpGroup,
      onLocation: selectRunLocation,
      onManageMachines: { settingsDestination = .machines(focusedMachineID: nil) },
      onManageProject: { managedProject = liveProject },
      onProjectDeleted: projectDeleted,
      sandboxes: sandboxPicks
    )
    .padding(.vertical, -6)
    .composerGlassSurface(
      shape: cardStyle.shape, id: .newChatConfiguration, in: glassNamespace
    )
    .padding(.vertical, 6)
    .disabled(
      controller.isSubmitting || controller.hasAcceptedFirstSend
    )
  }

  private var sandboxPicks: ComposerSandboxPicks {
    let machines = environment.machines
    let serverId = controller.project.serverId
    let enabled = sandboxesEnabled
    return ComposerSandboxPicks(
      enabled: enabled,
      selectedProfileId: controller.sandboxTarget?.profileId,
      load: { [controller] catalog in
        await catalog.load(from: machines.client(for: serverId), enabled: enabled) {
          machines.client(forServerId: $0)
        }
        if !enabled { controller.sandboxTarget = nil }
      },
      onPick: selectSandbox,
      onManage: { settingsDestination = .section("sandboxes") }
    )
  }

  private func selectSandbox(_ choice: SandboxProfileChoice) {
    guard choice.isEnabled else { return }
    controller.onSandboxReady = { [weak controller] previous, relocated, project in
      SandboxSessionRelocation.relocate(
        previous, to: relocated, project: project,
        projectList: environment.projectList, workspaces: environment.workspaces)
      guard let controller else { return }
      ChatControllerCache.shared.reregister(controller, from: previous, to: relocated)
    }
    controller.sandboxTarget = choice.target
  }

  private var liveProject: Project {
    environment.projectList.fleetActiveProjects.first {
      $0.serverId == controller.project.serverId && $0.id == controller.project.id
    } ?? controller.project
  }

  func selectTargetMachine(_ machine: CodevisorMachine) {
    let current = controller.project
    if controller.sandboxTarget != nil {
      controller.sandboxTarget = nil
      if machine.id == current.serverId { return }
    }
    guard machine.id != current.serverId,
      environment.machines.availability(for: machine.id) == .ready
    else { return }
    let currentGroup =
      current.isRunTargetPlaceholder
      ? pendingSetupGroup : environment.projectList.fleetProjectGroup(containing: current)
    if let linked = currentGroup?.member(on: machine.id) {
      selectTargetProject(linked, wantsWorktree: controller.wantsNewWorktree)
      return
    }
    if let currentGroup {
      pendingSetupGroupID = currentGroup.id
      applyRunTarget(.runTargetPlaceholder(serverId: machine.id), wantsWorktree: false)
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

  func selectSetUpGroup(_ group: ProjectGroup) {
    pendingSetupGroupID = group.id
    guard !controller.project.isRunTargetPlaceholder else { return }
    applyRunTarget(.runTargetPlaceholder(serverId: controller.project.serverId), wantsWorktree: false)
  }

  func selectTargetProject(_ project: Project, wantsWorktree: Bool? = nil) {
    pendingSetupGroupID = nil
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
