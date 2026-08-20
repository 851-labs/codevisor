import Foundation
import ACPKit
import os

extension SessionController {
    /// Sends the composer text, transitioning immediately into the transcript.
    /// Worktree and agent setup render after the optimistic first user message.
    public func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty,
            !isConnecting,
            configurationValidationState == .ready,
            !isSubmitting
        else { return }
        showsNewChatAfterSetupFailure = false
        status = .idle
        // Ask at the first moment notifications become useful instead of at
        // launch: the user just started work that may finish while they are in
        // another app. The task is intentionally nonblocking for the send.
        if let notificationDelivery {
            Task { await notificationDelivery.prepareAuthorizationIfNeeded() }
        }
        isSubmitting = true

        // Settle eager uploads first; a failed attachment blocks the send with
        // an inline status instead of silently dropping the file.
        guard let attachments = await collectAttachmentsForSend() else {
            isSubmitting = false
            return
        }
        let outgoingMessage = UserMessage(text: text, attachments: attachments)
        let shouldAnimateTranscriptSend = !isSending
        // Sending expresses "take me to the newest content": the transcript
        // re-pins only once the send is certain to proceed.
        userSendSignal &+= 1

        // Publish one client-owned optimistic row together with its animation
        // request. A connected model will adopt this exact id synchronously;
        // a model-less send keeps the same row visible while setup catches up.
        // In either case the transcript never observes a request without its
        // target, so native host readiness adds no extra send-state round trip.
        if shouldAnimateTranscriptSend {
            pendingUserMessage = outgoingMessage
            requestUserSendAnimation(for: outgoingMessage.id)
        }

        // A brand-new chat renders its pre-chat steps as setup sections; a
        // resumed session's transcript shouldn't grow one retroactively.
        let showsSetupPhases =
            (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
            && resumeAgentSessionId == nil
        // Clear the durable draft before mounting any first-send destination.
        // The source UIKit editor keeps its already-rendered pixels until the
        // transition surface covers it, while every newly mounted composer
        // starts empty. Publishing this after `onFirstSend` let the promotion
        // composer briefly rebuild with stale text, producing the visible
        // empty -> sent text -> empty pop.
        let staged = composerAttachments
        composerText = ""
        composerAttachments = []
        // Materialize the durable session before setup so the workspace and
        // pane keep a stable identity even if setup fails.
        if !hasSentFirst {
            hasSentFirst = true
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false

        func restoreComposer() {
            composerText = text
            composerAttachments = staged
            pendingUserMessage = nil
            cancelUserSendAnimation(for: outgoingMessage.id)
        }

        // Materialize the worktree before the agent exists, so it is born
        // with the worktree cwd. Progress (including checkout-hook output)
        // streams into the "Setting up worktree…" section.
        if wantsNewWorktree, sessionCwdOverride == nil {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
                return
            }
        }

        if let model {
            await model.send(outgoingMessage)
            if pendingUserMessage?.id == outgoingMessage.id {
                pendingUserMessage = nil
            }
            return
        }

        guard let harness = selectedHarness else {
            let message = "No agent is installed. Install Claude Code or Codex and try again."
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
            return
        }
        status = .connecting("Starting \(harness.name)…")
        if showsSetupPhases { beginSetupPhase(.startingAgent(named: harness.name)) }
        do {
            let model = try await connect(harnessId: harness.id)
            self.model = model
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
            await model.send(outgoingMessage)
            if pendingUserMessage?.id == outgoingMessage.id {
                pendingUserMessage = nil
            }
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
        }
    }

    func requestUserSendAnimation(for messageID: UUID) {
        userSendAnimationRequest = userSendAnimationCoordinator.issue(for: messageID)
    }

    /// Called by a native transcript only after the target row is mounted and
    /// ready to start its animation. The coordinator, rather than the view,
    /// owns consumption so remounting cannot replay the request.
    public func claimUserSendAnimation(_ request: UserSendAnimationRequest) -> Bool {
        userSendAnimationCoordinator.claim(request)
    }

    private func cancelUserSendAnimation(for messageID: UUID) {
        guard let request = userSendAnimationRequest, request.messageID == messageID else { return }
        userSendAnimationCoordinator.cancel(request)
        userSendAnimationRequest = nil
    }

    /// Continues the failed response in place. Automatic retries remain
    /// provider-owned; this explicit recovery starts a new assistant attempt
    /// under the original user message without duplicating that message.
    public func retryTurn(_ assistantID: UUID) async {
        guard let model, !model.isSending, !isConnecting, !isSubmitting else { return }
        guard
            let assistantIndex = model.conversation.firstIndex(where: { item in
                if case let .assistant(message) = item { return message.id == assistantID }
                return false
            })
        else { return }
        guard
            let prompt = model.conversation[..<assistantIndex].reversed().compactMap({ item in
                if case let .user(message) = item { return message }
                return nil
            }).first
        else { return }
        await model.retryResponse(to: prompt)
    }

    /// Asks the server to create a git worktree for this draft. The server
    /// owns the fixed location (~/codevisor/{projectId}/{name}) and picks a
    /// random memorable name; the app never computes either. The worktree id
    /// is generated client-side so the server's `worktree.setup` events (git
    /// output, checkout hooks, failures) can be followed live into the setup
    /// section while the request is in flight. Returns the failure message on
    /// error (nil on success); the caller either continues the transcript
    /// transition or restores New Chat.
    func createWorktree(showsSetupPhase: Bool) async -> String? {
        guard let serverClient else {
            return "Worktrees need the Codevisor server. Start it and try again."
        }
        let worktreeId = UUID().uuidString.lowercased()
        if showsSetupPhase { beginSetupPhase(.worktree()) }
        status = .connecting("Setting up worktree…")
        // Best-effort live tail: the WebSocket usually opens well before git
        // (and any long checkout hooks) produce output. Terminal state comes
        // from the HTTP response, not from these events.
        let follow = Task { [weak self] in
            do {
                for try await envelope in serverClient.eventStream(
                    since: ServerSessionTransport.liveOnlyEventCursor
                ) {
                    guard
                        case let .log(stream, line) = WorktreeSetupEvent.from(
                            envelope, worktreeId: worktreeId
                        )
                    else { continue }
                    self?.mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) {
                        $0.appendLog(stream: stream, line: line)
                    }
                }
            } catch {
                // The stream is cosmetic; a drop just stops the live tail.
                Log.session.debug("worktree setup log tail dropped: \(String(describing: error), privacy: .public)")
            }
        }
        defer { follow.cancel() }
        do {
            let worktree = try await serverClient.createWorktree(
                projectId: project.id,
                id: worktreeId,
                name: nil
            )
            sessionCwdOverride = worktree.path
            worktreeName = worktree.name
            // The session record was registered before the worktree existed;
            // carry the name/cwd onto it so the first connect (and terminals)
            // run in the worktree.
            if var session = serverSession {
                session.worktreeName = worktree.name
                session.cwd = worktree.path
                serverSession = session
            }
            onWorktreeCreated?(worktree)
            mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.succeed() }
            status = .idle
            return nil
        } catch let CodevisorServerClientError.httpStatus(_, message) {
            return WorktreeCreator.failureMessage(from: message)
        } catch {
            return serverErrorMessage(error)
        }
    }

    /// Failed first-send setup returns to the centered composer with its prompt
    /// restored. Existing-session failures remain in the transcript.
    func handleSetupFailure(_ message: String, returnsToNewChat: Bool) {
        if returnsToNewChat {
            setupPhases.removeAll()
            // Restore the original draft lifecycle so every composer field is
            // persisted again while the user edits or retries. The durable
            // session remains registered; only this controller's draft-facing
            // state is reset.
            hasSentFirst = false
            pendingNewChatAnalytics = false
            showsNewChatAfterSetupFailure = true
            status = .failed(message)
            onSetupFailed?()
            onSetupFailed = nil
            return
        }
        status = .failed(message)
    }

    func beginSetupPhase(_ phase: SessionSetupPhase) {
        setupPhases.removeAll { $0.id == phase.id }
        setupPhases.append(phase)
    }

    func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void) {
        guard let index = setupPhases.firstIndex(where: { $0.id == id }) else { return }
        transform(&setupPhases[index])
    }

    public func stop() async {
        await model?.cancel()
    }

    @discardableResult
    public func updateQueuedPrompt(id: String, text: String) async -> Bool {
        await model?.updateQueuedPrompt(id: id, text: text) ?? false
    }

    @discardableResult
    public func deleteQueuedPrompt(id: String) async -> Bool {
        await model?.deleteQueuedPrompt(id: id) ?? false
    }

    public func setMode(_ modeId: String) async {
        if let model {
            await model.setMode(modeId)
        } else {
            pendingModeId = modeId
        }
    }
}
