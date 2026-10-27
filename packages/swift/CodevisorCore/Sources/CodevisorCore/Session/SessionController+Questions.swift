import Foundation
import ACPKit
import os

extension SessionController {
  public var activeQuestion: QuestionRequest? { pendingQuestion ?? planApprovalRequest }

  public var pendingQuestion: QuestionRequest? { model?.pendingQuestion }

  public var composerQuestion: QuestionRequest? {
    guard let pendingQuestion, SessionModel.asksInTurn(pendingQuestion.questions) else {
      return activeQuestion
    }
    return planApprovalRequest
  }

  public var transcriptQuestion: QuestionRequest? {
    guard let pendingQuestion, TranscriptQuestion.asksInTranscript(pendingQuestion.questions) else { return nil }
    return pendingQuestion
  }

  public var isAwaitingAnswer: Bool { transcriptQuestion != nil }

  public func questionDraft(for request: QuestionRequest) -> QuestionDraft {
    if let draft = questionDrafts[request.questionId] { return draft }
    let draft = QuestionDraft(request: request)
    questionDrafts[request.questionId] = draft
    return draft
  }

  public func revealTranscriptQuestion() {
    transcriptQuestionRevealSignal &+= 1
  }

  public func submitTranscriptQuestion(_ id: String) async {
    guard let draft = questionDrafts[id], transcriptQuestion?.questionId == id, draft.isSubmittable else { return }
    await resolveTranscriptQuestion { await $0.answerQuestion(answers: draft.answers) }
  }

  public func answerTranscriptQuestion(_ id: String, with answers: [String: QuestionAnswerEntry]) async {
    guard transcriptQuestion?.questionId == id else { return }
    await resolveTranscriptQuestion { await $0.answerQuestion(answers: answers) }
  }

  public func skipTranscriptQuestion(_ id: String) async {
    guard transcriptQuestion?.questionId == id else { return }
    await resolveTranscriptQuestion { await $0.cancelQuestion() }
  }

  private func resolveTranscriptQuestion(_ resolve: (SessionModel) async -> Void) async {
    guard !isResolvingQuestion, let model else { return }
    isResolvingQuestion = true
    defer { isResolvingQuestion = false }
    await resolve(model)
  }

  public func setupRequest(id: String) -> TranscriptSetupRequest? {
    for item in [activeItem].compactMap(\.self) + settledConversation.reversed() {
      if case let .assistant(message) = item,
        let request = message.turn.setupRequests.first(where: { $0.id == id })
      {
        return request
      }
    }
    return nil
  }

  public func completeSetupRequest(_ id: String) async {
    guard let question = pendingQuestion, question.questionId == id, let spec = question.questions.first else {
      return
    }
    await answerQuestion(answers: [spec.id: QuestionAnswerEntry(answers: [spec.options.first?.label ?? "Continue"])])
  }

  public func declineSetupRequest(_ id: String) async {
    guard pendingQuestion?.questionId == id else { return }
    await cancelQuestion()
  }

  public func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
    guard !isResolvingQuestion else { return }
    isResolvingQuestion = true
    defer { isResolvingQuestion = false }
    if pendingPlanApproval {
      await resolvePlanApproval(answers)
      return
    }
    if answers[QuestionRequest.exitPlanModeId]?.answers.first == QuestionRequest.implementPlanLabel,
      isPlanModeOn
    {
      await togglePlanMode()
    }
    await model?.answerQuestion(answers: answers)
  }

  public func cancelQuestion() async {
    guard !isResolvingQuestion else { return }
    isResolvingQuestion = true
    defer { isResolvingQuestion = false }
    if pendingPlanApproval {
      pendingPlanApproval = false
      if let session = serverSession {
        try? await serverClient?.clearSessionPlanApproval(id: session.id)
      }
      return
    }
    await model?.cancelQuestion()
  }

  public func performBrowserExtensionSetupAction(_ action: String) async {
    guard let serverClient else { return }
    do {
      switch action {
      case "Open Extensions":
        _ = try await serverClient.openBrowserExtensionsPage()
      case "Show Folder":
        _ = try await serverClient.openBrowserExtensionFolder()
      case "Open Web Store":
        _ = try await serverClient.openBrowserExtensionWebStore()
      default:
        return
      }
    } catch {
      Log.server.error(
        "Failed to open browser extension setup destination: \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func browserExtensionArchive() async throws -> URL {
    guard let serverClient else {
      throw CodevisorServerClientError.invalidResponse
    }
    return try await serverClient.browserExtensionArchive()
  }

  public func browserExtensionIcon() async throws -> URL {
    guard let serverClient else {
      throw CodevisorServerClientError.invalidResponse
    }
    return try await serverClient.browserExtensionIcon()
  }

  private var usesPostTurnPlanApproval: Bool {
    (connectedHarnessId ?? selectedHarnessId) == "codex"
  }

  private var planApprovalRequest: QuestionRequest? {
    guard pendingPlanApproval else { return nil }
    return QuestionRequest(
      questionId: "codex-plan-approval",
      questions: [
        QuestionSpec(
          id: QuestionRequest.exitPlanModeId,
          header: "Plan",
          question: "Ready to implement this plan?",
          options: [
            QuestionOption(label: QuestionRequest.implementPlanLabel, description: "Start building"),
            QuestionOption(
              label: QuestionRequest.keepPlanningLabel, description: "Keep refining in plan mode"),
          ],
          allowsOther: false
        )
      ]
    )
  }

  func noteTurnEndedForPlanApproval() {
    guard usesPostTurnPlanApproval, isPlanModeOn, !pendingPlanApproval else { return }
    guard case let .assistant(message) = conversation.last,
      let plan = message.turn.planDocument, !plan.isEmpty
    else { return }
    pendingPlanApproval = true
  }

  private func resolvePlanApproval(_ answers: [String: QuestionAnswerEntry]) async {
    pendingPlanApproval = false
    if let session = serverSession {
      try? await serverClient?.clearSessionPlanApproval(id: session.id)
    }
    let entry = answers[QuestionRequest.exitPlanModeId]
    let note = (entry?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if entry?.answers.first == QuestionRequest.implementPlanLabel {
      if isPlanModeOn { await togglePlanMode() }
      userSendSignal &+= 1
      await model?.send(note.isEmpty ? "Implement the plan." : "Implement the plan.\n\n\(note)")
    } else if !note.isEmpty {
      userSendSignal &+= 1
      await model?.send(note)
    }
  }

  private enum PlanControl {
    case sessionMode(planId: String, buildId: String)
    case configOption(optionId: String, planValue: String, buildValue: String)
  }

  private var planControl: PlanControl? {
    if let modeState,
      let plan = modeState.availableModes.first(where: { $0.canonicalMode == .plan }),
      let build = modeState.availableModes.first(where: { $0.canonicalMode == .fullAccess })
        ?? modeState.availableModes.first(where: { $0.canonicalMode != .plan })
    {
      return .sessionMode(planId: plan.id, buildId: build.id)
    }
    if let option = modeConfigOption,
      let plan = option.options.first(where: { Self.matches("^plan", $0.value, $0.name) }),
      let build = option.options.first(where: { Self.matches("bypass|full[-_ ]?access|yolo", $0.value, $0.name) })
        ?? option.options.first(where: { $0.value != plan.value })
    {
      return .configOption(optionId: option.id, planValue: plan.value, buildValue: build.value)
    }
    return nil
  }

  private var modeConfigOption: SessionConfigOption? {
    configOptions.first { $0.category == SessionConfigOption.Category.mode || $0.id == "mode" }
  }

  private static let planPatternRegexes: [String: NSRegularExpression] = {
    let patterns = ["^plan", "bypass|full[-_ ]?access|yolo"]
    return Dictionary(
      uniqueKeysWithValues: patterns.map {
        ($0, try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]))
      })
  }()

  private static func matches(_ pattern: String, _ candidates: String...) -> Bool {
    guard let regex = planPatternRegexes[pattern] else {
      return candidates.contains {
        $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
      }
    }
    return candidates.contains {
      regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
    }
  }

  public var hasPlanMode: Bool { planControl != nil }

  public var isPlanModeOn: Bool {
    if let pendingPlanModeOn { return pendingPlanModeOn }
    switch planControl {
    case let .sessionMode(planId, _):
      return modeState?.currentModeId == planId
    case let .configOption(optionId, planValue, _):
      return configOptions.first { $0.id == optionId }?.currentValue == planValue
    case nil:
      return false
    }
  }

  public var isPlanModeUpdatePending: Bool { pendingPlanModeOn != nil }

  public func togglePlanMode() async {
    guard pendingPlanModeOn == nil, let planControl else { return }
    let targetIsOn = !isPlanModeOn
    if targetIsOn, isGoalComposerArmed {
      exitGoalComposer()
    }
    pendingPlanModeOn = targetIsOn
    defer { pendingPlanModeOn = nil }

    switch planControl {
    case let .sessionMode(planId, buildId):
      await setMode(targetIsOn ? planId : buildId)
    case let .configOption(optionId, planValue, buildValue):
      await setConfigOption(optionId, targetIsOn ? planValue : buildValue)
    }
  }
}
