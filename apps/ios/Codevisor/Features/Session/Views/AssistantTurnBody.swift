import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

struct AssistantTurnBody: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptController) private var transcriptController
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    @Environment(\.transcriptPerformAnchoredDisclosureChange)
    private var performAnchoredDisclosureChange
    @Environment(\.transcriptInvalidateRowMeasurement)
    private var invalidateRowMeasurement
    @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
    @State private var hasAutoCollapsed: Bool
    let turn: AssistantTurn
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID
    let isWaitingOnUser: Bool
    let waitingOnBackgroundTask: String?
    let goalActivity: GoalActivity?
    let presentation: AssistantTurnPresentation

    init(
        turn: AssistantTurn,
        turnId: UUID,
        isWaitingOnUser: Bool = false,
        waitingOnBackgroundTask: String? = nil,
        goalActivity: GoalActivity? = nil,
        presentation: AssistantTurnPresentation = .complete
    ) {
        self.turn = turn
        self.turnId = turnId
        self.isWaitingOnUser = isWaitingOnUser
        self.waitingOnBackgroundTask = waitingOnBackgroundTask
        self.goalActivity = goalActivity
        self.presentation = presentation
        _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var isGenerating: Bool { turn.isGenerating }

    private var sectionKeys: [TranscriptDisclosureStore.Key] {
        switch presentation {
        case .complete: [.turn(turnId), .turnImplementation(turnId)]
        case .planning: [.turn(turnId)]
        case .result: [.turnImplementation(turnId)]
        }
    }

    private func isExpanded(_ key: TranscriptDisclosureStore.Key) -> Bool {
        store.isExpanded(key, default: !settled)
    }

    /// A subagent that outlives its turn keeps the worked section open and
    /// its shimmer running, exactly like macOS.
    private var hasRunningSubagent: Bool {
        !runningSubagents.isDisjoint(with: turn.subagents.keys)
    }

    private var settled: Bool {
        (!isGenerating || turn.finalTextIsAsserted) && !hasRunningSubagent
    }
    @State private var hasActiveTextEntranceAnimation = false

    var body: some View {
        let _ = textAnimationPresentation.establishBaseline(
            settling: turn,
            turnID: turnId
        )
        let finalText = turn.finalText
        let postResponseGoalActivity = finalText == nil ? nil : goalActivity
        VStack(alignment: .leading, spacing: 14) {
            if presentation.showsPlanning {
                workedSection(
                    items: turn.workedItemsBeforePlan,
                    key: .turn(turnId),
                    showsTimer: turn.planBoundary == nil,
                    allowsDeferred: true
                )
            }
            if presentation.showsPlanDocument, let planDocument = turn.planDocument {
                PlanDocumentView(markdown: planDocument)
            }
            if presentation.showsResult {
                // Deferred detail hydrates through the first section only;
                // this row begins with post-plan implementation work.
                workedSection(
                    items: turn.workedItemsAfterPlan,
                    key: .turnImplementation(turnId),
                    showsTimer: true,
                    allowsDeferred: false
                )
                if !isWaitingOnUser, isGenerating, let retry = turn.retryStatus {
                    ChatActivityRow(retryLabel(retry))
                } else if postResponseGoalActivity == nil,
                    !isWaitingOnUser,
                    turn.showsActivityIndicator,
                    turn.contextCompactionStatus != .started
                {
                    if turn.isThinking {
                        ShimmeringText.thinking
                    } else if !hasActiveTextEntranceAnimation {
                        // Commentary is not `finalText`, but its glyph fade is
                        // still visible activity and wins over this fallback.
                        ShimmeringText(text: "Waiting on harness...")
                    }
                }
                if case let .text(entryID, markdown) = finalText {
                    assistantResponse(entryID: entryID, markdown: markdown)
                    if let waitingOnBackgroundTask {
                        ShimmeringText.waitingOnBackgroundTask(waitingOnBackgroundTask)
                    }
                    if !isGenerating {
                        MessageCopyButton(text: markdown, help: "Copy response")
                    }
                }
                if finalText == nil, !turn.attachments.isEmpty {
                    assistantResponse(entryID: "attachments", markdown: "")
                }
                if !isWaitingOnUser, let postResponseGoalActivity {
                    ShimmeringText(text: goalActivityLabel(postResponseGoalActivity))
                }
                if !isGenerating, let stopDetail = turn.stopDetail {
                    turnErrorRow(stopDetail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
            hasActiveTextEntranceAnimation = active
        }
        .onChange(of: isGenerating) { _, generating in
            if generating {
                if !hasAutoCollapsed {
                    for key in sectionKeys { store.setExpanded(key, true) }
                    invalidateRowMeasurement?()
                }
                return
            }
            autoCollapse()
        }
        .onChange(of: turn.finalTextIsAsserted) { _, asserted in
            if asserted, isGenerating { autoCollapse() }
        }
        .onChange(of: hasRunningSubagent) { _, running in
            if !running, !isGenerating { autoCollapse() }
        }
    }

    @ViewBuilder
    private func assistantResponse(entryID: String, markdown: String) -> some View {
        let segments = assistantMarkdownSegments(
            markdown,
            attachments: turn.attachments,
            includeServerPaths: !isGenerating
        )
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case let .markdown(value):
                    if !value.isEmpty {
                        StreamingMarkdownView(
                            value,
                            isComplete: !isGenerating,
                            streamID: TranscriptStreamingTextIdentity.main(
                                turnID: turnId,
                                entryID: "\(entryID):\(index)"
                            ),
                            animationPresentation: textAnimationPresentation
                        )
                    }
                case let .file(file, label):
                    VStack(alignment: .leading, spacing: 4) {
                        AttachmentThumbnailView(file: file, inline: true)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func turnErrorRow(_ message: String) -> some View {
        if let transcriptController,
            transcriptController.errorRequiresHarnessAuthentication,
            transcriptController.errorMessage == message
        {
            ChatErrorRow(
                message,
                actionTitle: "Open Settings",
                action: {
                    NotificationCenter.default.post(name: .codevisorOpenSettings, object: nil)
                }
            )
        } else if let transcriptController,
            transcriptController.canRetryTurn(turnId)
        {
            ChatErrorRow(
                message,
                actionTitle: "Retry response",
                action: { Task { await transcriptController.retryTurn(turnId) } }
            )
        } else {
            ChatErrorRow(message)
        }
    }

    private func retryLabel(_ retry: RetryStatus) -> String {
        guard let attempt = retry.attempt, let of = retry.of else { return retry.message }
        return "\(retry.message) \(attempt)/\(of)"
    }

    private func goalActivityLabel(_ activity: GoalActivity) -> String {
        switch activity {
        case .planning: "Planning…"
        case .verifying: "Verifying…"
        }
    }

    private func autoCollapse() {
        guard !hasAutoCollapsed, !hasRunningSubagent else { return }
        hasAutoCollapsed = true
        for key in sectionKeys { store.setExpanded(key, false) }
        invalidateRowMeasurement?()
    }

    /// One worked section: open with a live timer while streaming (not
    /// user-collapsible, as on macOS), a tappable "Worked for Ns" summary
    /// once settled.
    @ViewBuilder
    private func workedSection(
        items: [WorkedItem],
        key: TranscriptDisclosureStore.Key,
        showsTimer: Bool,
        allowsDeferred: Bool
    ) -> some View {
        if !items.isEmpty || (allowsDeferred && turn.hasDeferredWorkedDetails) {
            let isExpanded = isExpanded(key)
            VStack(alignment: .leading, spacing: 12) {
                if isGenerating, !hasAutoCollapsed {
                    workedHeader(
                        label: sectionLabel(showsTimer: showsTimer),
                        showsChevron: false,
                        expanded: isExpanded
                    )
                } else {
                    Button {
                        let change = {
                            if isExpanded {
                                store.setExpanded(key, false)
                            } else {
                                store.requestReveal(key)
                                store.setExpanded(key, true)
                            }
                            invalidateRowMeasurement?()
                        }
                        performAnchoredDisclosureChange?(change) ?? change()
                    } label: {
                        workedHeader(
                            label: sectionLabel(showsTimer: showsTimer),
                            showsChevron: true,
                            expanded: isExpanded
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // As on macOS: the divider belongs to the disclosure header,
                // not its revealed contents, so a rendered Worked section
                // keeps the line collapsed and expanded alike.
                Divider()

                if isExpanded {
                    WorkedContentReveal(key: key, store: store) {
                        VStack(alignment: .leading, spacing: 12) {
                            if allowsDeferred, turn.hasDeferredWorkedDetails,
                                let itemId = turn.deferredDetailItemId,
                                let transcriptController
                            {
                                DeferredWorkedDetails(
                                    controller: transcriptController,
                                    itemId: itemId
                                )
                            } else {
                                TurnItemsView(
                                    items: items,
                                    turn: turn,
                                    turnId: turnId,
                                    depth: 0,
                                    isTurnActive: isGenerating,
                                    animationPresentation: textAnimationPresentation
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func workedHeader(label: some View, showsChevron: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            label
            if showsChevron {
                TranscriptDisclosureChevron(expanded: expanded)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    /// "Working for 12s" (live) while streaming; "Planned" for the planning
    /// section once a plan boundary exists; "Worked for 12s" settled.
    @ViewBuilder
    private func sectionLabel(showsTimer: Bool) -> some View {
        if isGenerating, showsTimer {
            TimelineView(.periodic(from: turn.startedAt ?? Date(), by: 1)) { context in
                Text("Working for \(Self.format(elapsedSeconds(to: context.date)))")
            }
        } else if !showsTimer {
            Text("Planned")
        } else {
            Text(workedTitle)
        }
    }

    private var workedTitle: String {
        guard let duration = turn.duration, duration >= 1 else { return "Worked for a moment" }
        return "Worked for \(Self.format(Int(duration.rounded())))"
    }

    private func elapsedSeconds(to date: Date) -> Int {
        guard let started = turn.startedAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(started)))
    }

    private static func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
