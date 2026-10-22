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
        missing = true
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
    let session = environment.projectList.newSession(
      in: project,
      title: Self.chatTitle(from: submittedText),
      harnessId: controller.selectedHarnessId,
      worktreeName: controller.worktreeName,
      cwd: controller.sessionCwdOverride,
      syncToServer: false
    )
    controller.serverSession = session
    controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
      projectList?.setWorktree(
        name: worktree.name,
        cwd: worktree.path,
        for: session.id,
        serverId: session.serverId
      )
    }
    ChatControllerCache.shared.register(
      controller,
      for: session,
      environment: environment
    )
    let workspace = environment.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: session.id,
        initialName: session.worktreeName ?? project.name,
        serverId: session.serverId,
        projectId: project.id,
        rootDirectory: session.cwd ?? project.folderURL.path,
        worktreeName: session.worktreeName,
        assignedWorkspaceId: environment.projectList.workspaceId(forSession: session.id)
      ),
      legacyGroups: environment.paneGroups
    )
    controller.hostWorkspaceId = workspace.id
    environment.composerDefaults.performPersistenceBatch(flushImmediately: true) {
      environment.composerDefaults.rememberNewWorkspaceProject(
        serverId: project.serverId,
        projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
      )
      if project.isGitRepository, !project.isScratch {
        environment.rememberSentRunLocation(newWorktree: controller.wantsNewWorktree, for: project)
      }
    }
    var state = panes
    if let index = state.panes.firstIndex(where: { $0.kind == .chat }) {
      state.panes[index].chatSessionId = session.id
    }
    var paneWorkspace = workspace
    Self.applyCompactPaneState(state, to: &paneWorkspace)
    environment.workspaces.save(paneWorkspace)
    if isNewChatPresentation {
      onDraftStarted?(session.id)
      return
    }
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
    guard controllers[chatId] == nil else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=local-controller-present"
      )
      return
    }
    guard let session = session(for: chatId) else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=session-missing"
      )
      return
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
      return
    }
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
    guard controller.model == nil, !controller.isConnecting else {
      IOSNavigationDiagnostics.record(
        "workspace.connectChat.skip",
        "session=\(Self.diagnosticID(chatId)) reason=\(controller.model != nil ? "model-present" : "already-connecting")"
      )
      return
    }
    if session.agentSessionId?.isEmpty != false {
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
}
