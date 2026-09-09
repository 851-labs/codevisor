import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Connection

extension WorkspaceScreen {
  func prepare() async {
    IOSNavigationDiagnostics.record(
      "workspace.prepare.begin",
      "session=\(activeSessionId.map(Self.diagnosticID) ?? "nil") controllers=\(controllers.count)"
    )
    guard let sessionId = activeSessionId else {
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
        // A pane sync already removed falls back to the last selection.
        state.selectPane(id: preferredPaneId)
      }
      paneState = state
      persistCompactPaneState(state)
      if let explicitlyOpenedPane {
        publishPane(explicitlyOpenedPane)
      }
      synchronizePaneStateFromWorkspace()
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

  // MARK: - The draft (a new chat, before its first send)

  /// Binds the app-wide retained draft controller and wires what its first
  /// send should do. Idempotent: re-runs harmlessly as the project list
  /// arrives.
  func setUpDraftIfNeeded() {
    guard isDraft, draftController == nil, !environment.machines.allMachines.isEmpty else { return }
    let project =
      draftProjectCandidate
      ?? .runTargetPlaceholder(serverId: resolvedServerId)
    // Every draft, including No Project, has one durable controller. Picker
    // changes retarget it in place, preserving attachments and configuration.
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

  /// The draft's first send: create the session and become its workspace,
  /// in place. The pane keeps its id and the transcript keeps its controller,
  /// so the chat view is never rebuilt — the run pickers simply collapse and
  /// the sent message rides its lift up into the history.
  private func adoptSession(
    for controller: SessionController,
    submittedText: String
  ) {
    guard let project = resolvedProject else { return }
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
        worktreeName: session.worktreeName
      ),
      legacyGroups: environment.paneGroups
    )
    environment.composerDefaults.performPersistenceBatch(flushImmediately: true) {
      // A scratch folder is single-use; remember the CHOICE of no
      // project rather than the folder it happened to get.
      environment.composerDefaults.rememberNewWorkspaceProject(
        serverId: project.serverId,
        projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id
      )
      environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
        serverId: project.serverId,
        createsWorktree: controller.wantsNewWorktree
      )
      controller.rememberCurrentComposerConfiguration()
      controller.moveComposerDefaults(
        to: .workspace(id: workspace.id, serverId: session.serverId)
      )
    }
    // Save the draft pane under the real session before Home mounts the
    // normal workspace route. Both containers resolve the same cached
    // controller and pane identity during the covered handoff.
    var state = panes
    if let index = state.panes.firstIndex(where: { $0.kind == .chat }) {
      state.panes[index].chatSessionId = session.id
    }
    var paneWorkspace = workspace
    Self.applyCompactPaneState(state, to: &paneWorkspace)
    environment.workspaces.save(paneWorkspace)
    environment.workspaceSync.noteLocalMutation()
    if isNewChatPresentation {
      // Keep the source draft hierarchy mounted until Home has moved
      // first-responder ownership into the independent promotion
      // window. Adopting the session in this sheet remounted its
      // composer immediately, which dismissed the keyboard hundreds of
      // milliseconds before the overlay editor existed.
      onDraftStarted?(session.id)
      return
    }
    controllers[session.id] = controller
    self.project = project
    startedSessionId = session.id
    paneState = state
    withAnimation(
      .timingCurve(
        0.22,
        1,
        0.36,
        1,
        duration: TranscriptSendAnimationMetrics.duration
      )
    ) {
      hasStarted = true
    }
    // Mount the genuine workspace route in the same send turn. The
    // covering surface and the optimistic row now start together instead
    // of waiting for the request to leave the composer.
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
    return firstLine.count > 48
      ? String(firstLine.prefix(48)) + "…"
      : (firstLine.isEmpty ? "New session" : firstLine)
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
    // App-wide cache: revisiting a chat rebinds the SAME controller, so a
    // stream that kept flowing while we were away renders immediately.
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
      // A fresh chat: no agent exists yet. Load harness capabilities so
      // the composer validates; the agent spawns on the first send.
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
