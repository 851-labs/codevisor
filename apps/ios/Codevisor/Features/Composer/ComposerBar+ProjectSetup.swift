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

  private func projectSetupModel() -> ProjectMachineSetup {
    if let projectSetup { return projectSetup }
    let machines = environment.machines
    let setup = ProjectMachineSetup(
      clientFor: { machines.client(for: $0) },
      machineName: { machines.machine(for: $0)?.name ?? "this machine" },
      isReachable: { machines.availability(for: $0) == .ready },
      adopt: { _ in }
    )
    projectSetupState.setup = setup
    return setup
  }

  func beginProjectSetupIfNeeded() -> Bool {
    guard controller.project.isRunTargetPlaceholder, let group = pendingSetupGroup else { return false }
    let setup = projectSetupModel()
    guard !setup.isPresented else { return true }
    setup.onFinished = { project in adoptSetUpProject(project) }
    let targetServerId = controller.project.serverId
    Task {
      await setup.prepare(
        group: group,
        targetServerId: targetServerId,
        preferredSource: environment.projectList.mostRecentlyUsedMember(of: group)
      )
    }
    return true
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
