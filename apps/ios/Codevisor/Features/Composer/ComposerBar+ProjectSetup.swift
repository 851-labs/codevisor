import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
@Observable
final class ComposerProjectSetupState {
  var pendingGroupID: ProjectGroup.ID?
  var setup: ProjectMachineSetup?
}

extension ComposerBar {
  var pendingSetupGroupID: ProjectGroup.ID? {
    get { projectSetupState.pendingGroupID }
    nonmutating set { projectSetupState.pendingGroupID = newValue }
  }

  var projectSetup: ProjectMachineSetup? { projectSetupState.setup }

  func withProjectSetup(_ content: some View) -> some View {
    content
      .sheet(isPresented: isShowingProjectSetup) {
        if let projectSetup { ProjectSetupScreen(setup: projectSetup) }
      }
      .onChange(of: controller.submitRequest) { _, _ in
        submitComposer()
      }
  }

  var pendingSetupGroup: ProjectGroup? {
    guard let pendingSetupGroupID else { return nil }
    return environment.projectList.fleetActiveProjectGroups.first { $0.id == pendingSetupGroupID }
  }

  private func makeProjectSetup() -> ProjectMachineSetup {
    ProjectMachineSetup(machines: environment.machines)
  }

  func beginProjectSetupIfNeeded() -> Bool {
    guard controller.project.isRunTargetPlaceholder else { return false }
    controller.projectClone = nil
    guard let group = pendingSetupGroup else { return false }
    if projectSetup?.isPresented == true { return true }

    let setup = makeProjectSetup()
    let preferredSource = environment.projectList.mostRecentlyUsedMember(of: group)
    if let plan = setup.clonePlan(
      group: group, targetServerId: controller.project.serverId, preferredSource: preferredSource)
    {
      let request = ProjectCloneRequest(plan: plan, setup: setup, projectList: environment.projectList)
      return holdsCloneSend(request)
    }
    beginProjectSetup(group, setup: setup)
    return true
  }

  private func holdsCloneSend(_ request: ProjectCloneRequest) -> Bool {
    let access = controller.projectCloneAccess
    guard !access.isChecking else { return true }
    guard access.isVerified(request.plan) else {
      checkCloneAccess(request.plan)
      return true
    }

    controller.projectClone = request
    controller.onProjectCloned = { project in adoptClonedProject(project) }
    return false
  }

  private func checkCloneAccess(_ plan: ProjectMachineSetup.Plan) {
    let failures = makeProjectSetup()
    projectSetupState.setup = failures
    controller.projectCloneAccess.check(plan, failuresOn: failures) { [weak controller] in
      controller?.requestSubmit()
    }
  }

  private func beginProjectSetup(_ group: ProjectGroup, setup: ProjectMachineSetup) {
    let targetServerId = controller.project.serverId
    projectSetupState.setup = setup
    setup.onFinished = { project in adoptSetUpProject(project) }
    Task {
      await setup.prepare(
        group: group,
        targetServerId: targetServerId,
        preferredSource: environment.projectList.mostRecentlyUsedMember(of: group)
      )
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

  private func adoptSetUpProject(_ project: Project) {
    pendingSetupGroupID = nil
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

  private var isShowingProjectSetup: Binding<Bool> {
    Binding(
      get: { projectSetup?.isPresented == true },
      set: { presented in
        guard !presented, let projectSetup, !projectSetup.isRunning else { return }
        if case .finished = projectSetup.phase { return }
        projectSetup.cancel()
      }
    )
  }
}
