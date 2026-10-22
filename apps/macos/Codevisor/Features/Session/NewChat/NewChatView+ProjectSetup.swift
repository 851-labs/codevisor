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
    let machines = environment.machines
    let setup = ProjectMachineSetup(
      clientFor: { machines.client(for: $0) },
      machineName: { machines.machine(for: $0)?.name ?? "this machine" },
      isReachable: { machines.availability(for: $0) == .ready },
      adopt: { _ in }
    )
    projectSetup = setup
    return setup
  }

  func installSendInterceptor(on controller: SessionController) {
    controller.sendInterceptor = { [weak controller] _ in
      guard let controller, controller.project.isRunTargetPlaceholder,
        let group = pendingSetupGroup
      else { return false }
      beginProjectSetup(group, controller: controller)
      return true
    }
  }

  private func beginProjectSetup(_ group: ProjectGroup, controller: SessionController) {
    let setup = projectSetupModel()
    guard !setup.isPresented else { return }
    setup.onFinished = { [weak controller] project in
      guard let controller else { return }
      adoptSetUpProject(project, controller: controller)
    }
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
