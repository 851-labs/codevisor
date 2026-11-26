import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension WorkspaceScreen {
  func prepare() async {
    IOSNavigationDiagnostics.record(
      "workspace.prepare.begin",
      "session=\(activeSessionId.map(Self.diagnosticID) ?? "nil") controllers=\(controllers.count)"
    )
    if isDraft {
      setUpDraftIfNeeded()
      guard let controller = draftController, controller.isServerReady else { return }
      let targetServerId = controller.project.serverId
      let client = environment.machines.client(for: targetServerId)
      controller.adoptServerClient(client, forServer: targetServerId)
      async let projects = environment.projectList.refreshFromServer(
        serverId: targetServerId, client: client
      )
      await controller.prepare()
      _ = await projects
      IOSNavigationDiagnostics.record("workspace.prepare.end", "draft=true")
      return
    }
    if paneState == nil, let paneStorageId {
      var explicitlyOpenedPane: PaneDescriptorState?
      var state =
        resolvedWorkspace.map(Self.compactPaneState(from:))
        ?? WorkspacePaneStore.shared.state(
          for: paneStorageId,
          legacySessionIds: legacyPaneSessionIds
        )
      if let preferredChatSessionId {
        if let pane = state.panes.first(where: {
          $0.kind == .chat && $0.chatSessionId == preferredChatSessionId
        }) {
          state.selectPane(id: pane.id)
        } else {
          explicitlyOpenedPane = state.addChatPane(sessionId: preferredChatSessionId)
        }
      }
      if let preferredPaneId {
        state.selectPane(id: preferredPaneId)
      }
      paneState = state
      persistCompactPaneState(state)
      if let explicitlyOpenedPane {
        publishPane(explicitlyOpenedPane)
      }
      synchronizePaneStateFromWorkspace()
    }
    guard let sessionId = activeSessionId else {
      project = resolvedProject
      serverConfig = environment.machines.serverConfig(for: resolvedServerId)
      return
    }
    if controllers[sessionId] == nil {
      guard let session = rootSession,
        let project = environment.projectList.projects.first(where: {
          $0.serverId == session.serverId && $0.id == session.projectId
        })
      else {
        missing = canShowServerContent
        IOSNavigationDiagnostics.record(
          "workspace.prepare.abort",
          "session=\(Self.diagnosticID(sessionId)) reason=session-or-project-missing"
        )
        return
      }
      self.project = project
      serverConfig = environment.machines.serverConfig(for: session.serverId)
    }
    await connectChat(sessionId: sessionId)
    IOSNavigationDiagnostics.record(
      "workspace.prepare.end",
      "session=\(Self.diagnosticID(sessionId)) controllers=\(controllers.count)"
    )
  }

  func setUpDraftIfNeeded() {
    guard isDraft, draftController == nil else { return }
    guard !environment.machines.allMachines.isEmpty else {
      IOSNavigationDiagnostics.record("workspace.draftSetup.skipped", "reason=no-machines")
      return
    }
    IOSNavigationDiagnostics.record("workspace.draftSetup", "server=\(resolvedServerId)")
    let project =
      draftProjectCandidate
      ?? .runTargetPlaceholder(serverId: resolvedServerId)
    let controller = ChatControllerCache.shared.draftController(
      preferredProject: project,
      environment: environment
    )
    serverConfig = environment.machines.serverConfig(for: controller.project.serverId)
    if paneState == nil {
      paneState = PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
    }
    controller.onScratchProjectCreated = { [weak projectList = environment.projectList] scratch in
      projectList?.registerServerProject(scratch)
    }
    controller.onFirstSend = { [weak controller] submittedText in
      guard let controller else { return }
      adoptSession(for: controller, submittedText: submittedText)
    }
    draftController = controller
  }

  private func adoptSession(
    for controller: SessionController,
    submittedText: String
  ) {
    guard let project = resolvedProject else { return }
    onDraftWillStart?()
    let session = startSession(for: controller, in: project, submittedText: submittedText)
    let workspace = draftWorkspace(for: session, in: project, awaitsOwnCheckout: controller.awaitsOwnCheckout)
    controller.hostWorkspaceId = workspace.id
    rememberNewChatChoices(of: controller, in: project)
    let state = assignChatPane(to: session, in: workspace)
    if isNewChatPresentation {
      onDraftStarted?(session.id)
      return
    }
    showStartedChat(session, controller: controller, project: project, panes: state)
  }

  private func startSession(
    for controller: SessionController,
    in project: Project,
    submittedText: String
  ) -> ChatSession {
    let session = environment.projectList.newSession(
      in: project,
      title: Self.chatTitle(from: submittedText),
      harnessId: controller.selectedHarnessId,
      worktreeName: controller.worktreeName,
      cwd: controller.sessionCwdOverride,
      syncToServer: false
    )
    controller.serverSession = session
    bindSessionCallbacks(of: controller, to: session)
    ChatControllerCache.shared.register(
      controller,
      for: session,
      environment: environment
    )
    return session
  }

  private func bindSessionCallbacks(of controller: SessionController, to session: ChatSession) {
    controller.onSetupFailed = { [weak controller] in
      guard let controller else { return }
      onDraftFailed?(DraftSetupFailure(environment: environment).discard(controller, startedAs: session))
    }
    controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
      projectList?.setWorktree(
        name: worktree.name,
        cwd: worktree.path,
        for: session.id,
        serverId: session.serverId
      )
    }
  }

  private func draftWorkspace(
    for session: ChatSession, in project: Project, awaitsOwnCheckout: Bool
  ) -> Workspace {
    environment.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: session.id,
        initialName: session.worktreeName ?? project.name,
        serverId: session.serverId,
        projectId: project.id,
        rootDirectory: awaitsOwnCheckout ? nil : session.cwd ?? project.folderURL.path,
        worktreeName: session.worktreeName,
        assignedWorkspaceId: environment.projectList.workspaceId(forSession: session.id)
      ),
      legacyGroups: environment.paneGroups
    )
  }

  private func rememberNewChatChoices(of controller: SessionController, in project: Project) {
    environment.composerDefaults.performPersistenceBatch(flushImmediately: true) {
      environment.composerDefaults.rememberNewWorkspaceProject(
        serverId: project.serverId,
        projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
      )
      if project.isGitRepository, !project.isScratch {
        environment.rememberSentRunLocation(newWorktree: controller.wantsNewWorktree, for: project)
      }
    }
  }

  private func assignChatPane(to session: ChatSession, in workspace: Workspace) -> PaneGroupState {
    var state = panes
    if let index = state.panes.firstIndex(where: { $0.kind == .chat }) {
      state.panes[index].chatSessionId = session.id
    }
    var paneWorkspace = workspace
    Self.applyCompactPaneState(state, to: &paneWorkspace)
    environment.workspaces.save(paneWorkspace)
    return state
  }

  private func showStartedChat(
    _ session: ChatSession,
    controller: SessionController,
    project: Project,
    panes state: PaneGroupState
  ) {
    controllers[session.id] = controller
    self.project = project
    startedSessionId = session.id
    paneState = state
    withAnimation(
      .spring(
        response: TranscriptSendMotion.content.response,
        dampingFraction: TranscriptSendMotion.content.dampingFraction
      )
    ) {
      hasStarted = true
    }
    onDraftStarted?(session.id)
  }

  func dismissNewChatPresentation() {
    if let onDismissNewChat {
      onDismissNewChat()
    } else {
      dismiss()
    }
  }

  private static func chatTitle(from prompt: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
    if firstLine.count > 48 { return String(firstLine.prefix(48)) + "…" }
    return firstLine.isEmpty ? "New session" : firstLine
  }

  func connectChat(sessionId chatId: UUID) async {
    IOSNavigationDiagnostics.record(
      "workspace.connectChat.begin",
      "session=\(Self.diagnosticID(chatId)) localController=\(controllers[chatId] != nil)"
    )
    guard let controller = controllers[chatId] ?? makeChatController(for: chatId) else { return }
    guard canShowServerContent else { return }

    if controller.isServerReady, case .failed = controller.status {
      await controller.retrySessionFailure()
      return
    }
    guard controller.model == nil || controller.showsCachedTranscript, !controller.isConnecting else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=\(controller.model != nil ? "model-present" : "already-connecting")"
      )
      return
    }
    await connect(controller, chatId: chatId)
  }

  private func makeChatController(for chatId: UUID) -> SessionController? {
    guard let (session, project) = chatSessionAndProject(for: chatId) else { return nil }

    let controller = ChatControllerCache.shared.controller(
      for: session,
      project: project,
      workspaceId: resolvedWorkspace?.id ?? activeSessionId ?? chatId,
      environment: environment
    )
    controllers[chatId] = controller
    IOSNavigationDiagnostics.record(
      "workspace.connectChat.controller",
      "session=\(Self.diagnosticID(chatId)) model=\(controller.model != nil) connecting=\(controller.isConnecting) historyLoading=\(controller.isLoadingInitialHistory)"
    )
    return controller
  }

  private func connect(_ controller: SessionController, chatId: UUID) async {
    controller.replaceUnreachableClient(with: environment.machines.client(for: controller.project.serverId))
    if controller.serverSession?.agentSessionId?.isEmpty != false {
      await controller.prepare()
      controller.applyComposerDefaults()
    }
    IOSNavigationDiagnostics.record("workspace.connectChat.connect.begin", "session=\(Self.diagnosticID(chatId))")
    await controller.connectIfNeeded()
    IOSNavigationDiagnostics.record(
      "workspace.connectChat.connect.end",
      "session=\(Self.diagnosticID(chatId)) model=\(controller.model != nil) connecting=\(controller.isConnecting) historyLoading=\(controller.isLoadingInitialHistory)"
    )
  }

  private func chatSessionAndProject(for chatId: UUID) -> (ChatSession, Project)? {
    guard let session = session(for: chatId) else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=session-missing"
      )
      return nil
    }
    guard
      let project = environment.projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      })
    else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=project-missing"
      )
      return nil
    }
    return (session, project)
  }
}
