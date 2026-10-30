import CodevisorCore
import Foundation

struct WorkspaceInspectorMainChatTasks {
  let workspace: Workspace
  let chat: ChatSession
  let store: SessionStore
  let client: any CodevisorServerClienting

  var tasks: [WorkspaceInspectorTask] {
    let key = SessionStore.SessionKey(serverId: chat.serverId, sessionId: chat.id)
    guard let controller = store.controllers[key] else { return [] }

    return controller.backgroundTasks.map { task in
      WorkspaceInspectorTask(
        task,
        actions: WorkspaceInspectorTask.Actions(
          showInChat: showInChat(task), readOutput: readOutput(task), stop: stop(task)))
    }
  }

  private func showInChat(_ task: BackgroundTaskInfo) -> (() -> Void)? {
    guard let toolCallId = task.toolUseId else { return nil }

    let destination = WorkspaceInspectorView.Destination.toolCall(sessionId: chat.id, toolCallId: toolCallId)
    return { [store, workspace] in
      store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(workspaceId: workspace.id, destination: destination)
    }
  }

  private func readOutput(_ task: BackgroundTaskInfo) -> (() async throws -> [String])? {
    guard task.hasOutput == true else { return nil }

    return { [client, chat] in try await client.backgroundTaskOutput(sessionId: chat.id, taskId: task.id).lines }
  }

  private func stop(_ task: BackgroundTaskInfo) -> (() async throws -> Void)? {
    guard task.canStop == true else { return nil }

    return { [client, chat] in try await client.stopBackgroundTask(sessionId: chat.id, taskId: task.id) }
  }
}
