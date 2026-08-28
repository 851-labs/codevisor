import Foundation
import ACPKit

extension SessionController {
    // MARK: - Goals

    /// The session's persistent goal, when the harness supports goal mode.
    public var goal: SessionGoal? { model?.goal }

    /// Whether the selected harness supports goals at all — gates every goal
    /// affordance; harnesses without support show nothing.
    public var supportsGoals: Bool {
        guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
        return supportsGoalsByHarness[harnessId] ?? false
    }

    /// The goal affordance shows whenever the harness supports goals; a goal
    /// set before the first send is held and applied once the agent connects.
    public var canEditGoal: Bool { supportsGoals }

    public func toggleGoalComposer() {
        if isGoalComposerArmed {
            exitGoalComposer()
        } else {
            isGoalComposerArmed = true
            // Plan and goal are mutually exclusive: arming the goal composer
            // leaves plan mode.
            if isPlanModeOn, !isPlanModeUpdatePending {
                Task { await togglePlanMode() }
            }
        }
    }

    /// Leaves goal mode without mutating an ordinary composer draft. Editing
    /// an existing goal restores the chat draft that the edit displaced.
    public func exitGoalComposer() {
        isGoalComposerArmed = false
        isGoalEditing = false
        if let composerTextBeforeGoalEdit {
            composerText = composerTextBeforeGoalEdit
            self.composerTextBeforeGoalEdit = nil
        }
    }

    /// Loads the current goal into the composer in edit mode — submitting
    /// replaces the objective.
    public func editGoal() {
        guard let objective = (goal ?? draftGoal)?.objective else { return }
        composerTextBeforeGoalEdit = composerText
        composerText = objective
        isGoalComposerArmed = true
        isGoalEditing = true
    }

    /// Submits the composer text as the goal (the armed-toggle send path).
    /// On a new chat this mirrors `send()`: navigate to the session page,
    /// create the worktree/session, connect the agent — with the goal applied
    /// on connect instead of a prompt.
    public func submitGoalFromComposer() async {
        let objective = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty, !isConnecting, !isSubmitting else { return }

        if let model {
            guard await model.setGoal(objective: objective) else { return }
            isGoalComposerArmed = false
            isGoalEditing = false
            composerText = composerTextBeforeGoalEdit ?? ""
            composerTextBeforeGoalEdit = nil
            return
        }

        isGoalComposerArmed = false
        isGoalEditing = false
        pendingGoal = objective
        showsNewChatAfterSetupFailure = false
        status = .idle
        isSubmitting = true
        let showsSetupPhases =
            (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
            && resumeAgentSessionId?.isEmpty != false
        // Navigate first, exactly like a first prompt send.
        if !hasSentFirst {
            hasSentFirst = true
            if onFirstSend != nil {
                pendingNewChatAnalytics = true
            }
            onFirstSend?()
            onFirstSend = nil
        }
        isSubmitting = false
        composerText = ""
        func restoreComposer() {
            composerText = objective
            pendingGoal = nil
            isGoalComposerArmed = true
        }

        // Materialize the worktree before the agent exists, exactly like a
        // first prompt send (see send()).
        if wantsNewWorktree, sessionCwdOverride == nil {
            if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
                restoreComposer()
                handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
                return
            }
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
            // connect applies the pending goal once the agent session exists.
            let model = try await connect(harnessId: harness.id)
            self.model = model
            setupPhases.removeAll { $0.id == SessionSetupPhase.agentPhaseId }
            status = .idle
        } catch {
            let message = serverErrorMessage(error)
            restoreComposer()
            handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
        }
    }

    @discardableResult
    public func setGoal(objective: String? = nil, status: GoalStatus? = nil) async -> Bool {
        if let model {
            return await model.setGoal(objective: objective, status: status)
        } else if let objective {
            pendingGoal = objective
            return true
        }
        return false
    }

    /// The pre-connect goal shown in the banner before the session exists.
    /// Kept visible until the live goal replaces it, so the banner doesn't
    /// flicker out during the connect handshake.
    public var draftGoal: SessionGoal? {
        guard model?.goal == nil, let pendingGoal else { return nil }
        return SessionGoal(objective: pendingGoal, status: .active)
    }

    /// Applies a goal captured before connect. Called once the model exists.
    /// The draft clears only after the live goal is set (no banner gap).
    func applyPendingGoal(to model: SessionModel) async {
        guard let pendingGoal else { return }
        if await model.setGoal(objective: pendingGoal) {
            self.pendingGoal = nil
        }
    }

    @discardableResult
    public func pauseGoal() async -> Bool { await model?.pauseGoal() ?? false }

    @discardableResult
    public func resumeGoal() async -> Bool { await model?.resumeGoal() ?? false }

    @discardableResult
    public func clearGoal() async -> Bool {
        if model == nil {
            pendingGoal = nil
            return true
        } else {
            return await model?.clearGoal() ?? false
        }
    }

    // MARK: - Todos

    /// The session's latest todo checklist, pinned above the composer.
    public var todos: Plan? { model?.sessionPlan }

    /// Fully completed snapshots remain durable for sync/cursor correctness,
    /// but no longer occupy any pinned checklist UI.
    public var visibleTodos: Plan? {
        guard let todos,
            todos.entries.contains(where: { $0.status != .completed })
        else {
            return nil
        }
        return todos
    }

    /// Restores the per-session disclosure preference after controller
    /// creation or LRU eviction.
    public func restoreTodoDisclosure(isExpanded: Bool) {
        isTodosExpanded = isExpanded
    }
}
