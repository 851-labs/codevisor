import CodevisorCore
import CodevisorUI
import SwiftUI

extension NewChatView {
  var pendingSetupGroup: ProjectGroup? {
    guard let pendingSetupGroupID else { return nil }
    return environment.projectList.fleetActiveProjectGroups.first { $0.id == pendingSetupGroupID }
  }

  func machineName(_ serverId: String) -> String {
    environment.machines.machine(for: serverId)?.name ?? "this machine"
  }

  func projectSetupModel() -> ProjectMachineSetup {
    if let projectSetup { return projectSetup }
    let setup = makeProjectSetup()
    projectSetup = setup
    return setup
  }

  private func makeProjectSetup() -> ProjectMachineSetup {
    let machines = environment.machines
    return ProjectMachineSetup(
      clientFor: { machines.client(for: $0) },
      machineName: { machines.machine(for: $0)?.name ?? "this machine" },
      isReachable: { machines.availability(for: $0) == .ready },
      adopt: { _ in }
    )
  }

  var pendingCloneGroup: ProjectGroup? {
    guard controller?.project.isRunTargetPlaceholder == true, let group = pendingSetupGroup, group.repoUrl != nil
    else { return nil }
    return group
  }

  func installSendInterceptor(on controller: SessionController) {
    controller.sendInterceptor = { [weak controller] _ in
      guard let controller, controller.project.isRunTargetPlaceholder else { return false }
      controller.projectClone = nil
      guard let group = pendingSetupGroup else { return false }
      return interceptSetupSend(group, controller: controller)
    }
  }

  private func interceptSetupSend(_ group: ProjectGroup, controller: SessionController) -> Bool {
    let cloneSetup = makeProjectSetup()
    let preferredSource = environment.projectList.mostRecentlyUsedMember(of: group)
    if let plan = cloneSetup.clonePlan(
      group: group, targetServerId: controller.project.serverId, preferredSource: preferredSource)
    {
      controller.projectClone = ProjectCloneRequest(
        plan: plan, setup: cloneSetup, projectList: environment.projectList)
      controller.onProjectCloned = { project in adoptClonedProject(project) }
      return false
    }
    let setup = projectSetupModel()
    guard !setup.isPresented else { return true }
    setup.onFinished = { [weak controller] project in
      guard let controller else { return }
      adoptSetUpProject(project, controller: controller)
    }
    beginProjectSetup(group, setup: setup, controller: controller)
    return true
  }

  private func adoptClonedProject(_ project: Project) {
    pendingSetupGroupID = nil
    environment.composerDefaults.rememberNewWorkspaceProject(serverId: project.serverId, projectId: project.id)
    Task {
      await environment.projectList.refreshFromServer(
        serverId: project.serverId,
        client: environment.machines.client(for: project.serverId)
      )
    }
  }

  private func beginProjectSetup(_ group: ProjectGroup, setup: ProjectMachineSetup, controller: SessionController) {
    let targetServerId = controller.project.serverId
    Task {
      await setup.prepare(
        group: group,
        targetServerId: targetServerId,
        preferredSource: environment.projectList.mostRecentlyUsedMember(of: group)
      )
    }
  }

  private func adoptSetUpProject(_ project: Project, controller: SessionController) {
    pendingSetupGroupID = nil
    selectedProjectId = project.id
    environment.composerDefaults.rememberNewWorkspaceProject(
      serverId: project.serverId,
      projectId: project.id
    )
    Task {
      await environment.projectList.refreshFromServer(
        serverId: project.serverId,
        client: environment.machines.client(for: project.serverId)
      )
      let live =
        environment.projectList.projects.first {
          $0.serverId == project.serverId && $0.id == project.id
        } ?? project
      await controller.selectProject(live)
      controller.wantsNewWorktree = environment.prefersNewWorktree(for: live)
      try? await Task.sleep(for: .milliseconds(500))
      projectSetup?.close()
      controller.requestSubmit()
    }
  }

  var isShowingProjectSetup: Binding<Bool> {
    Binding(
      get: { projectSetup?.isPresented == true },
      set: { presented in
        guard !presented, let projectSetup, !projectSetup.isRunning else { return }
        if case .finished = projectSetup.phase { return }
        projectSetup.cancel()
      }
    )
  }

  @ViewBuilder
  var projectSetupSheet: some View {
    if let projectSetup {
      ProjectSetupSheet(setup: projectSetup)
    }
  }
}
