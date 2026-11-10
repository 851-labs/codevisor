import CodevisorClient
import CodevisorCore
import Observation

@MainActor
@Observable
final class WorkspaceInspectorRemoteTasks {
  private static let refreshInterval = Duration.seconds(5)

  private(set) var tasks: [WorkspaceInspectorTask] = []

  func keepLoading(workspace: Workspace, client: any CodevisorServerClienting, machines: MachineController) async {
    while !Task.isCancelled {
      await load(workspace: workspace, client: client, machines: machines)
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }

  private func load(workspace: Workspace, client: any CodevisorServerClienting, machines: MachineController) async {
    guard let loaded = try? await client.remoteExecTasks(workspaceId: workspace.id) else { return }
    tasks = loaded.map { task in
      let machineId = machines.machineId(forSyncKey: task.machine.machineId) ?? task.machine.machineId
      let machine =
        machineId == workspace.serverId ? nil : WorkspaceInspectorTask.Machine(id: machineId, name: task.machine.name)
      return inspectorTask(task, machine: machine, workspace: workspace, client: client)
    }
  }

  private func inspectorTask(
    _ task: ServerRemoteExecTask, machine: WorkspaceInspectorTask.Machine?, workspace: Workspace,
    client: any CodevisorServerClienting
  ) -> WorkspaceInspectorTask {
    let actions = WorkspaceInspectorTask.Actions(
      readOutput: { try await client.remoteExecTaskOutput(workspaceId: workspace.id, taskId: task.taskId) },
      stop: { [weak self] in
        try await client.stopRemoteExecTask(workspaceId: workspace.id, taskId: task.taskId)
        self?.tasks.removeAll { $0.id == task.taskId }
      })
    return WorkspaceInspectorTask(task, machine: machine, actions: actions)
  }
}
