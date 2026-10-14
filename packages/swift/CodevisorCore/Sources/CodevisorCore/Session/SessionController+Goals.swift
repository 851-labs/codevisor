import Foundation
import ACPKit

extension SessionController {
  public var goal: SessionGoal? { model?.goal }

  public var supportsGoals: Bool {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
    return supportsGoalsByHarness[harnessId] ?? false
  }

  public var canEditGoal: Bool { supportsGoals }

  public func toggleGoalComposer() {
    if isGoalComposerArmed {
      exitGoalComposer()
    } else {
      isGoalComposerArmed = true
      if isPlanModeOn, !isPlanModeUpdatePending {
        Task { await togglePlanMode() }
      }
    }
  }

  public func exitGoalComposer() {
    isGoalComposerArmed = false
    isGoalEditing = false
    if let composerTextBeforeGoalEdit {
      composerText = composerTextBeforeGoalEdit
      self.composerTextBeforeGoalEdit = nil
    }
  }

  public func editGoal() {
    guard let objective = (goal ?? draftGoal)?.objective else { return }
    composerTextBeforeGoalEdit = composerText
    composerText = objective
    isGoalComposerArmed = true
    isGoalEditing = true
  }

  public func submitGoalFromComposer() async {
    let objective = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty, !isConnecting, !isSubmitting,
      isServerReady, configurationValidationState == .ready,
      !requiresModelSelection,
      model != nil || selectedHarness != nil
    else { return }

    if let model {
      await pendingConfiguration.apply(to: model)
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
    if !hasSentFirst {
      firstSendSelections = rememberedConfigValues
      hasSentFirst = true
      if onFirstSend != nil {
        pendingNewChatAnalytics = true
      }
      onFirstSend?(objective)
      onFirstSend = nil
    }
    isSubmitting = false
    composerText = ""
    func restoreComposer() {
      composerText = objective
      pendingGoal = nil
      isGoalComposerArmed = true
    }

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
      let model = try await connect(harnessId: harness.id)
      self.model = model
      await pendingConfiguration.apply(to: model)
      await applyPendingGoal(to: model)
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
      await pendingConfiguration.apply(to: model)
      return await model.setGoal(objective: objective, status: status)
    } else if let objective {
      pendingGoal = objective
      return true
    }
    return false
  }

  public var draftGoal: SessionGoal? {
    guard model?.goal == nil, let pendingGoal else { return nil }
    return SessionGoal(objective: pendingGoal, status: .active)
  }

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

  public var todos: Plan? { model?.sessionPlan }

  public var visibleTodos: Plan? {
    guard let todos,
      todos.entries.contains(where: { $0.status != .completed })
    else {
      return nil
    }
    return todos
  }

  public func restoreTodoDisclosure(isExpanded: Bool) {
    isTodosExpanded = isExpanded
  }
}
