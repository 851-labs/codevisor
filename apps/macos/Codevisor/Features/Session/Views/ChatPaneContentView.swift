import CodevisorCore
import SwiftUI
import CodevisorUI

struct ChatPaneContentView: View {
  let descriptor: PaneDescriptorState
  let group: PaneGroupModel?
  let focus: TerminalFocusController
  let session: ChatSession?
  let hostWorkspace: Workspace
  let project: Project
  let store: SessionStore
  let environment: AppEnvironment
  var role = ChatPaneRole.chat

  var body: some View {
    if let chatSessionId = role.sessionId(of: descriptor) {
      if let chatSession = environment.projectList.session(chatSessionId, serverId: hostWorkspace.serverId),
        let chatProject = environment.projectList.projects.first(where: {
          $0.serverId == hostWorkspace.serverId && $0.id == chatSession.projectId
        })
      {
        if role.offersNewChat, isUnstarted(chatSession) {
          NewChatView(
            store: store,
            selection: .constant(nil),
            initialProjectTarget: NewChatTarget(chatProject),
            paneDraftId: descriptor.id,
            onCreatedInPane: { created in
              (group ?? session.map { store.centerPaneGroup(for: $0, project: project) })?
                .assignChatSession(
                  paneId: descriptor.id,
                  sessionId: created.id,
                  name: created.title
                )
            },
            preCreatedSession: chatSession,
            paneFocus: focus,
            hostWorkspaceId: hostWorkspace.id
          )
        } else {
          let controller = sessionController(for: chatSession, project: chatProject)
          ChatScreen(
            controller: controller,
            focus: focus,
            presentationSurface: store.transcriptSurface(
              for: chatSession,
              paneID: descriptor.id,
              controller: controller
            ),
            isReadOnly: role.isReadOnly,
            botMode: role.botMode
          )
          .environment(
            \.computerUsePiPPane,
            ComputerUsePiPPane(workspaceId: hostWorkspace.id, paneId: descriptor.id)
          )
          .id(chatSession.id)
          .task(id: SessionStore.SessionKey(chatSession)) {
            store.noteAccess(SessionStore.SessionKey(chatSession))
          }
          .onChange(of: chatSession, initial: true) { _, updatedSession in
            store.reconcile(controller, for: updatedSession, project: chatProject)
          }
          .onChange(of: chatProject) { _, updatedProject in
            store.reconcile(controller, for: chatSession, project: updatedProject)
          }
          .attachmentDropTarget(role.isReadOnly ? nil : controller)
        }
      } else {
        VStack(spacing: 12) {
          Text("This chat no longer exists")
            .foregroundStyle(.secondary)
          if let group {
            Button("Reset Tab") {
              group.resetChatPaneToPlaceholder(id: descriptor.id)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      NewChatView(
        store: store,
        selection: .constant(nil),
        initialProjectTarget: NewChatTarget(project),
        paneDraftId: descriptor.id,
        onCreatedInPane: { created in
          (group ?? session.map { store.centerPaneGroup(for: $0, project: project) })?
            .assignChatSession(
              paneId: descriptor.id,
              sessionId: created.id,
              name: created.title
            )
        },
        hostWorkspaceId: hostWorkspace.id
      )
    }
  }

  private func sessionController(for chatSession: ChatSession, project chatProject: Project) -> SessionController {
    guard role == .fullTranscript else { return store.controller(for: chatSession, project: chatProject) }
    return store.transcriptViewer(
      for: chatSession, project: chatProject, paneID: descriptor.id, workspaceId: viewerWorkspaceId)
  }

  private var viewerWorkspaceId: UUID? {
    group == nil ? nil : hostWorkspace.id
  }

  private func isUnstarted(_ chatSession: ChatSession) -> Bool {
    guard let live = store.activeController(for: chatSession) else {
      return !chatSession.hasAgentSession
    }
    if live.shouldShowNewChatComposer { return true }
    if live.hasAcceptedFirstSend { return false }
    guard !chatSession.hasAgentSession else { return false }
    return
      !(live.isConnected
      || live.isConnecting
      || live.isSending
      || live.pendingUserMessage != nil)
  }
}
