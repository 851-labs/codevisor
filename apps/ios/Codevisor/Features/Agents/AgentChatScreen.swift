import CodevisorCore
import CodevisorUI
import SwiftUI

struct AgentChatScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.windowID) private var windowID
  let serverId: String
  let sessionId: UUID
  var setsTitle = true
  @State private var controller: SessionController?

  private var session: ChatSession? {
    environment.projectList.session(sessionId, serverId: serverId)
  }

  var body: some View {
    titled
      .task(id: session?.id) { await connect() }
      .onAppear { IOSNavigationDiagnostics.record("agentChat.appear", "controller=\(controller != nil)") }
  }

  @ViewBuilder
  private var titled: some View {
    if setsTitle {
      content
        .navigationTitle(session?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
    } else {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if let session, let controller {
      SessionTranscriptView(
        controller: controller,
        presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
          for: .init(paneID: session.id, isNewChat: false, windowID: windowID),
          controller: controller
        ),
        isReadOnly: session.isArchived,
        preservesComposerFocusOnSend: true
      )
      .id(session.id)
    } else if session == nil {
      ContentUnavailableView(
        "Agent Unavailable",
        systemImage: "bubble.left.and.exclamationmark.bubble.right",
        description: Text("This agent was archived or its machine is not connected.")
      )
    } else {
      DelayedWorkspaceLoadingView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ChatSurfaceBackground().ignoresSafeArea() }
    }
  }

  private func connect() async {
    guard let session,
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else { return }
    let controller = ChatControllerCache.shared.controller(
      for: session, project: project, workspaceId: nil, environment: environment)
    controller.isGuestInHostWorkspace = true
    self.controller = controller
    IOSNavigationDiagnostics.record("agentChat.controller", "model=\(controller.model != nil)")
    guard controller.model == nil, !controller.isConnecting else { return }
    await controller.connectIfNeeded()
    IOSNavigationDiagnostics.record("agentChat.connected", "model=\(controller.model != nil)")
  }
}
