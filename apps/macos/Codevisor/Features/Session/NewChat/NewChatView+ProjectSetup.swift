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

  private func makeProjectSetup() -> ProjectMachineSetup {
    ProjectMachineSetup(machines: environment.machines)
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
    if projectSetup?.isPresented == true { return true }

    let setup = makeProjectSetup()
    let preferredSource = environment.projectList.mostRecentlyUsedMember(of: group)
    if let plan = setup.clonePlan(
      group: group, targetServerId: controller.project.serverId, preferredSource: preferredSource)
    {
      let request = ProjectCloneRequest(plan: plan, setup: setup, projectList: environment.projectList)
      return interceptCloneSend(request, controller: controller)
    }
    projectSetup = setup
    setup.onFinished = { [weak controller] project in
      guard let controller else { return }
      adoptSetUpProject(project, controller: controller)
    }
    beginProjectSetup(group, setup: setup, controller: controller)
    return true
  }

  private func interceptCloneSend(_ request: ProjectCloneRequest, controller: SessionController) -> Bool {
    let access = controller.projectCloneAccess
    guard !access.isChecking else { return true }
    guard access.isVerified(request.plan) else {
      checkCloneAccess(request.plan, controller: controller)
      return true
    }

    controller.projectClone = request
    controller.onProjectCloned = { project in adoptClonedProject(project) }
    return false
  }

  private func checkCloneAccess(_ plan: ProjectMachineSetup.Plan, controller: SessionController) {
    let failures = makeProjectSetup()
    projectSetup = failures
    controller.projectCloneAccess.check(plan, failuresOn: failures) { [weak controller] in
      controller?.requestSubmit()
    }
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
