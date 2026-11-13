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

  private var isReadOnly: Bool { role.isReadOnly || isArchivedBot }

  private var isArchivedBot: Bool {
    guard let sessionId = descriptor.chatSessionId else { return false }
    return environment.bots.bot(forSession: sessionId, serverId: hostWorkspace.serverId)?.isArchived == true
  }

  var body: some View {
    if let chatSessionId = role.sessionId(of: descriptor) {
      switch resolver.chat(chatSessionId, on: hostWorkspace.serverId) {
      case let .ready(chatSession, chatProject):
        if let bot = conversationBot, let thread = environment.botThreads.openThread(of: bot) {
          threadScreen(thread, of: bot, chat: chatSession, in: chatProject)
        } else if role.offersNewChat, isUnstarted(chatSession) {
          unstartedChat(chatSession, in: chatProject)
        } else {
          chatScreen(chatSession, in: chatProject)
        }
      case let .connecting(machine):
        PaneChatUnavailableView(reason: .connecting(machine))
      case let .offline(machine):
        PaneChatUnavailableView(reason: .offline(machine)) {
          Task { await environment.machines.retryMachine(machine.id) }
        }
      case .missing:
        PaneChatUnavailableView(reason: .missing, action: resetToPlaceholder)
      }
    } else {
      NewChatView(
        store: store,
        selection: .constant(nil),
        initialProjectTarget: NewChatTarget(project),
        paneDraftId: descriptor.id,
        onCreatedInPane: assignCreatedChat,
        hostWorkspaceId: hostWorkspace.id
      )
    }
  }

  private var conversationBot: Bot? {
    guard role == .botConversation, let sessionId = descriptor.chatSessionId else { return nil }
    return environment.bots.bot(forSession: sessionId, serverId: hostWorkspace.serverId)
  }

  private var resetToPlaceholder: (() -> Void)? {
    guard let group else { return nil }
    return { [descriptor] in group.resetChatPaneToPlaceholder(id: descriptor.id) }
  }

  private var resolver: PaneChatResolver {
    PaneChatResolver(projectList: environment.projectList, machines: environment.machines)
  }

  private func unstartedChat(_ chatSession: ChatSession, in chatProject: Project) -> some View {
    NewChatView(
      store: store,
      selection: .constant(nil),
      initialProjectTarget: NewChatTarget(chatProject),
      paneDraftId: descriptor.id,
      onCreatedInPane: assignCreatedChat,
      preCreatedSession: chatSession,
      paneFocus: focus,
      hostWorkspaceId: hostWorkspace.id
    )
  }

  private func threadScreen(
    _ thread: ServerThread, of bot: Bot, chat chatSession: ChatSession, in chatProject: Project
  ) -> some View {
    let viewerId = UUID(uuidString: thread.threadId) ?? descriptor.id
    let controller = store.transcriptViewer(for: chatSession, project: chatProject, paneID: viewerId, workspaceId: nil)
    return BotThreadScreen(
      bot: bot,
      thread: thread,
      controller: controller,
      surface: store.transcriptSurface(for: chatSession, paneID: viewerId, controller: controller),
      focus: focus
    )
    .onDisappear { store.releaseTranscriptViewer(paneID: viewerId, sessionID: chatSession.id) }
  }

  private func chatScreen(_ chatSession: ChatSession, in chatProject: Project) -> some View {
    let controller = sessionController(for: chatSession, project: chatProject)
    return ChatScreen(
      controller: controller,
      focus: focus,
      presentationSurface: store.transcriptSurface(
        for: chatSession,
        paneID: descriptor.id,
        controller: controller
      ),
      isReadOnly: isReadOnly,
      presentsBotConversation: role == .botConversation
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
    .attachmentDropTarget(isReadOnly ? nil : controller)
    .task(id: conversationBot?.id) {
      if let bot = conversationBot { await environment.botThreads.refreshThreads(of: bot) }
    }
  }

  private func assignCreatedChat(_ created: ChatSession) {
    (group ?? session.map { store.centerPaneGroup(for: $0, project: project) })?
      .assignChatSession(
        paneId: descriptor.id,
        sessionId: created.id,
        name: created.title
      )
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
