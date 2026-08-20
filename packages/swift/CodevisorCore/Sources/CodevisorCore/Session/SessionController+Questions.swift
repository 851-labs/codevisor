import Foundation
import ACPKit
import os

extension SessionController {
    // MARK: - Questions

    /// The question the composer renders as a picker: a real blocking agent
    /// question, or codex's client-side plan approval (below) when neither the
    /// server nor a tool drives it.
    public var activeQuestion: QuestionRequest? { pendingQuestion ?? planApprovalRequest }

    /// The blocking agent question the composer renders as a picker.
    public var pendingQuestion: QuestionRequest? { model?.pendingQuestion }

    public func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
        guard !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
        // Codex's plan approval is a client-side prompt with no server question
        // to answer — resolve it by messaging the model, not via the server.
        if pendingPlanApproval {
            await resolvePlanApproval(answers)
            return
        }
        // Accepting Claude's ExitPlanMode approval ("Implement plan") also leaves
        // plan mode, so the agent implements in build mode and the composer
        // toggle reflects the move from planning to building. Switch first, then
        // release the held tool.
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
        // Dismissing codex's plan prompt just keeps planning: no message, back
        // to the composer.
        if pendingPlanApproval {
            pendingPlanApproval = false
            if let session = serverSession {
                try? await serverClient?.clearSessionPlanApproval(id: session.id)
            }
            return
        }
        await model?.cancelQuestion()
    }

    /// Opens one browser-extension setup destination without resolving the
    /// blocking agent question. These are utility actions, so the composer
    /// must remain mounted while Chrome or Finder opens.
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

    /// Opens Chrome's extension page and reveals the prepared extension on
    /// the computer running the session. iOS uses this instead of downloading
    /// a desktop archive it cannot install locally.
    public func openBrowserExtensionInstaller() async throws {
        guard let serverClient else {
            throw CodevisorServerClientError.invalidResponse
        }
        _ = try await serverClient.installDevelopmentBrowserExtension()
    }

    // MARK: - Codex plan approval

    /// Only harnesses that propose plans without a blocking approval tool use
    /// this post-turn prompt (Claude's ExitPlanMode already drives its own).
    private var usesPostTurnPlanApproval: Bool {
        (connectedHarnessId ?? selectedHarnessId) == "codex"
    }

    /// The synthetic picker for the client-side plan approval, mirroring the
    /// server-built one Claude sends.
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

    /// Fired at turn end: raise the plan prompt when a codex plan-mode turn
    /// proposed a plan.
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
            // Approve: leave plan mode and tell the model to build. Codex has no
            // exit-plan tool, so this rides as a normal user message.
            if isPlanModeOn { await togglePlanMode() }
            userSendSignal &+= 1
            await model?.send(note.isEmpty ? "Implement the plan." : "Implement the plan.\n\n\(note)")
        } else if !note.isEmpty {
            // Keep planning, but a note is refinement feedback — send it so the
            // model iterates (still in plan mode).
            userSendSignal &+= 1
            await model?.send(note)
        }
        // Keep planning with no note: nothing to send; the composer returns.
    }

    // MARK: - Plan mode

    /// How plan mode is controlled for the selected harness. ACP has no plan
    /// capability flag (modes only arrive with `session/new`), so support is
    /// detected by inspecting what the harness exposes: a session mode mapped
    /// onto the canonical plan vocabulary, or — for harnesses like OpenCode
    /// that ship modes as a config select instead of ACP session modes — a
    /// mode-category config option with a plan-ish value.
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

    /// The mode-category config select, for harnesses without ACP session
    /// modes (e.g. OpenCode's build/plan). Hidden from the picker chips and
    /// driven by the plan toggle instead.
    private var modeConfigOption: SessionConfigOption? {
        configOptions.first { $0.category == SessionConfigOption.Category.mode || $0.id == "mode" }
    }

    /// Mirrors the server's canonical-mode patterns (agent-runtime acp.ts) so
    /// the app and server recognize the same plan/full-access spellings.
    /// Precompiled once: `matches` runs several times per composer keystroke
    /// via `planControl`, and `String.range(of:options:.regularExpression)`
    /// compiles a fresh regex on every call.
    private static let planPatternRegexes: [String: NSRegularExpression] = {
        let patterns = ["^plan", "bypass|full[-_ ]?access|yolo"]
        return Dictionary(
            uniqueKeysWithValues: patterns.map {
                ($0, try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]))
            })
    }()

    private static func matches(_ pattern: String, _ candidates: String...) -> Bool {
        guard let regex = planPatternRegexes[pattern] else {
            // Unknown pattern: fall back to the uncached path.
            return candidates.contains {
                $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        return candidates.contains {
            regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
    }

    /// Whether the composer shows the plan toggle at all — needs a plan mode
    /// and a build/full-access mode to come back to.
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
        // The button is disabled while pending too, but keep the guard here so
        // multiple click tasks queued before SwiftUI redraws cannot submit the
        // same transition more than once.
        guard pendingPlanModeOn == nil, let planControl else { return }
        let targetIsOn = !isPlanModeOn
        // Plan and goal are mutually exclusive: entering plan mode disarms
        // the goal composer.
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
