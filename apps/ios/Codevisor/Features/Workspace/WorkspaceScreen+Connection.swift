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
            // Stale while revalidate, matching macOS New Chat: construct from
            // the persisted project snapshot before the first suspension, then
            // refresh metadata without holding the sheet behind a spinner.
            setUpDraftIfNeeded()
            await environment.projectList.refreshFromServer()
            setUpDraftIfNeeded()
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
    func setUpDraftIfNeeded(preferredProject: Project? = nil) {
        guard isDraft else { return }
        guard let project = preferredProject ?? draftProjectCandidate
        else {
            setUpPlaceholderDraftIfNeeded()
            return
        }
        // A project arrived (or was picked) while the project-less sentinel
        // held the composer: carry the typed text into the real draft.
        var carriedText = ""
        if let sentinel = draftController, draftIsPlaceholderBorn {
            carriedText = sentinel.composerText
            draftController = nil
            draftIsPlaceholderBorn = false
        }
        guard draftController?.keepOrRetargetDraft(to: project) != true else { return }
        // The retained draft: leaving and coming back — or relaunching —
        // restores the unsent message, attachments, and picked run location.
        let controller = ChatControllerCache.shared.draftController(
            preferredProject: project,
            environment: environment
        )
        serverConfig = environment.machines.serverConfig(for: controller.project.serverId)
        // Pin the draft's pane group NOW: `centerInitial` mints a fresh pane id
        // each call, so leaving it computed would hand the chat view a new
        // identity every render — remounting it constantly.
        if paneState == nil {
            paneState = PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
        }
        controller.onFirstSend = { [weak controller] in
            guard let controller else { return }
            adoptSession(for: controller)
        }
        if !carriedText.isEmpty, controller.composerText.isEmpty {
            controller.composerText = carriedText
        }
        draftController = controller
        Task { await controller.prepare() }
    }

    /// No project exists on the selected machine yet: the composer still
    /// renders, bound to a sentinel project. Send stays disabled and the
    /// run-target chip reads "Select a Project…". The sentinel can load the
    /// selected machine's harness catalog but is never cached or persisted.
    /// Picking a real project swaps it for the durable draft while preserving the chosen harness.
    private func setUpPlaceholderDraftIfNeeded() {
        guard draftController == nil else { return }
        let serverId = environment.defaultComposerServerId
        let controller = SessionController.runTargetPlaceholder(
            serverId: serverId,
            environment: environment
        )
        serverConfig = environment.machines.serverConfig(
            for: serverId
        )
        if paneState == nil {
            paneState = PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
        }
        draftIsPlaceholderBorn = true
        draftController = controller
        Task { await controller.prepare() }
    }

    /// The draft's first send: create the session and become its workspace,
    /// in place. The pane keeps its id and the transcript keeps its controller,
    /// so the chat view is never rebuilt — the run pickers simply collapse and
    /// the sent message rides its lift up into the history.
    private func adoptSession(for controller: SessionController) {
        guard let project = resolvedProject else { return }
        let session = environment.projectList.newSession(
            in: project,
            // `send()` clears the durable draft before this callback so every
            // destination composer mounts empty. The optimistic row is the
            // authoritative snapshot of the outgoing prompt at this point.
            title: Self.chatTitle(
                from: controller.pendingUserMessage?.text ?? controller.composerText
            ),
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
            environment.composerDefaults.rememberNewWorkspaceProject(
                serverId: project.serverId,
                projectId: project.id
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
