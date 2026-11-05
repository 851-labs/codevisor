import CodevisorCore
import CodevisorUI

struct DraftSetupFailure {
  let environment: AppEnvironment

  func discard(_ controller: SessionController, startedAs session: ChatSession) -> ChatSession {
    TranscriptSendStaging.shared.cancel(session: ObjectIdentifier(controller))
    let started = controller.serverSession ?? session
    let workspaceId = environment.workspaces.workspaceId(forSession: started.id)
    controller.serverSession = nil
    controller.onAgentSessionCreated = nil
    ChatControllerCache.shared.returnToDraft(controller, from: started, environment: environment)
    environment.projectList.withdrawExpectedSession(started)
    if let workspaceId { environment.workspaces.delete(id: workspaceId) }
    return started
  }
}
