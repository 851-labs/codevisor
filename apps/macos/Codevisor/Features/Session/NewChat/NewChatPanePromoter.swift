import CodevisorCore
import Foundation

@MainActor
enum NewChatPanePromoter {
  static func promote(
    paneId: UUID,
    in model: PaneGroupModel,
    project: Project,
    workspace: Workspace,
    environment: AppEnvironment
  ) -> ChatSession? {
    guard model.state.panes.contains(where: { $0.id == paneId && $0.kind == .newTab })
    else { return nil }
    let session = environment.projectList.newSession(
      in: project,
      title: "New Chat",
      worktreeName: workspace.worktreeName,
      cwd: workspace.rootDirectory,
      syncToServer: false
    )
    model.convertNewTabPane(
      id: paneId,
      to: .chat,
      chatSessionId: session.id,
      name: session.title,
      publishChange: false
    )
    guard
      let pane = model.state.panes.first(where: {
        $0.id == paneId && $0.kind == .chat && $0.chatSessionId == session.id
      })
    else { return nil }
    environment.workspaceSync.promotePaneToChat(
      pane,
      session: session,
      workspaceId: workspace.id,
      client: environment.machines.client(for: session.serverId)
    )
    return session
  }
}
