import Foundation
import ACPKit

extension SessionController {
  public var goal: SessionGoal? { model?.goal }

  public var supportsGoals: Bool {
    guard !project.isBot, let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
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
    guard !objective.isEmpty, isReadyToSubmit else { return }

    if let model {
      await updateGoal(of: model, to: objective)
    } else {
      await startChat(withGoal: objective)
    }
  }

  private func updateGoal(of model: SessionModel, to objective: String) async {
    await pendingConfiguration.apply(to: model)
    guard await model.setGoal(objective: objective) else { return }

    isGoalComposerArmed = false
    isGoalEditing = false
    composerText = composerTextBeforeGoalEdit ?? ""
    composerTextBeforeGoalEdit = nil
  }

  private func startChat(withGoal objective: String) async {
    isGoalComposerArmed = false
    isGoalEditing = false
    pendingGoal = objective
    beginSubmission()
    defer { isFirstSendConnecting = false }
    composerText = ""

    func restoreComposer() {
      composerText = objective
      pendingGoal = nil
      isGoalComposerArmed = true
    }

    await prepareSession(for: objective, restoreComposer: restoreComposer)
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
