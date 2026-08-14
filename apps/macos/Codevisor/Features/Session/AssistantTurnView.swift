import ACPKit
import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

/// Which chronological slice of a settled assistant turn this row owns.
/// Active turns use `.complete`; settled plan turns split into planning and
/// result rows with `PlanDocumentView` virtualized independently between them.
enum AssistantTurnPresentation: Equatable {
    case complete
    case planning
    case result

    var showsPlanning: Bool { self != .result }
    var showsPlanDocument: Bool { self == .complete }
    var showsResult: Bool { self != .planning }
}

/// Renders one assistant turn: reasoning text and tool-call groups collapse into
/// a "Worked for…" disclosure, the final answer renders expanded at the bottom,
/// and a truthful activity status shows while the agent is working or waiting.
struct AssistantTurnView: View {
    let turn: AssistantTurn
    /// Stable id of the owning assistant message — the disclosure key, stable
    /// across the active→settled transition and lazy remounts.
    let turnID: UUID
    let isWaitingOnUser: Bool
    let waitingOnBackgroundTask: String?
    /// Explicit goal work shown after the current response. Unlike Thinking…,
    /// this can remain active while a final-looking answer is being verified.
    let goalActivity: GoalActivity?
    let presentation: AssistantTurnPresentation
    private let initiallyExpanded: Bool?
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIds
    @Environment(\.transcriptController) private var transcriptController
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    /// Turn-scoped semantic stream ledger. Existing entries are seeded as
    /// settled when this row mounts (including a navigation remount); entries
    /// first created afterward retain their initial live entrance animation.
    @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
    /// Transient one-shot guard for the finish/assert auto-collapse. Stays
    /// `@State`: it only matters while the turn is generating/settling, which
    /// is the mounted active row. A settled remount resets it harmlessly.
    @State private var hasAutoCollapsed = false
    @State private var isHovered = false
    @State private var hasActiveTextEntranceAnimation = false

    init(
        turn: AssistantTurn,
        turnID: UUID = UUID(),
        initiallyExpanded: Bool? = nil,
        isWaitingOnUser: Bool = false,
        waitingOnBackgroundTask: String? = nil,
        goalActivity: GoalActivity? = nil,
        presentation: AssistantTurnPresentation = .complete
    ) {
        self.turn = turn
        self.turnID = turnID
        self.initiallyExpanded = initiallyExpanded
        self.isWaitingOnUser = isWaitingOnUser
        self.waitingOnBackgroundTask = waitingOnBackgroundTask
        self.goalActivity = goalActivity
        self.presentation = presentation
        _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
    }

    // Disclosure hoisted to the session store so lazy remounts preserve it.
    // The default reproduces the old init seeding: expanded while running,
    // collapsed once finished / when a provider-asserted final is streaming.
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

    /// Both worked sections: planning (above the plan card) and the
    /// implementation that follows approval (below it).
    private var sectionKeys: [TranscriptDisclosureStore.Key] {
        switch presentation {
        case .complete: [.turn(turnID), .turnImplementation(turnID)]
        case .planning: [.turn(turnID)]
        case .result: [.turnImplementation(turnID)]
        }
    }

    private func isExpanded(_ key: TranscriptDisclosureStore.Key) -> Bool {
        // A subagent still running in the background keeps the section
        // "unsettled" so it defaults open until the work finishes, even after
        // the turn ended.
        let settled = (!turn.isGenerating || turn.finalTextIsAsserted) && !turnHasRunningSubagent
        return store.isExpanded(key, default: initiallyExpanded ?? !settled)
    }

    /// True while any subagent spawned by this turn is still running in the
    /// background — the turn can end before its subagents finish.
    private var turnHasRunningSubagent: Bool {
        !runningSubagentToolCallIds.isEmpty
            && turn.subagents.keys.contains { runningSubagentToolCallIds.contains($0) }
    }

    /// Match the actual collapsible content: streaming by itself is represented
    /// by the separate activity indicator and must not create an empty Worked
    /// disclosure.
    private func showsPlanningSection(_ items: [WorkedItem]) -> Bool {
        if turn.hasDeferredWorkedDetails { return true }
        return !items.isEmpty
    }

    var body: some View {
        let _ = textAnimationPresentation.establishBaseline(
            settling: turn,
            turnID: turnID
        )
        let beforePlan = turn.workedItemsBeforePlan
        let afterPlan = turn.workedItemsAfterPlan
        // Hoisted: `finalText` re-scans the turn's entries per read, and this
        // body runs on every streaming flush.
        let finalText = turn.finalText
        // Goal planning can begin before the assistant has said anything. In
        // that phase the ordinary Thinking…/tool activity remains the single
        // progress signal. The goal-specific label appears only once there is
        // a response for it to follow in transcript order.
        let postResponseGoalActivity = finalText == nil ? nil : goalActivity
        VStack(alignment: .leading, spacing: 14) {
            // Planning/exploration collapses into the first "Worked for…"
            // section, above the proposed plan.
            if presentation.showsPlanning, showsPlanningSection(beforePlan) {
                workedSection(items: beforePlan, key: .turn(turnID), timerLabel: turn.planBoundary == nil)
            }

            if presentation.showsPlanDocument,
               let planDocument = turn.planDocument, !planDocument.isEmpty {
                PlanDocumentView(markdown: planDocument)
            }
            // The step checklist lives in the pinned TodoPanelView above the
            // composer (session-level, all harnesses) rather than per turn.

            // Once the plan is approved, the implementation gets its own
            // "Worked for…" section BELOW the plan, so approved work reads in
            // order (plan → build) instead of piling up above the plan card.
            if presentation.showsResult, !afterPlan.isEmpty {
                workedSection(items: afterPlan, key: .turnImplementation(turnID), timerLabel: true)
            }

            // A transient failure (e.g. 529 overload) is being retried — show it
            // instead of the plain "Thinking…" so the chat isn't a silent freeze.
            if presentation.showsResult,
               !isWaitingOnUser, turn.isGenerating, let retry = turn.retryStatus {
                ChatActivityRow(retryLabel(retry))
            } else if postResponseGoalActivity == nil, presentation.showsResult,
                      !isWaitingOnUser, turn.showsActivityIndicator,
                      turn.contextCompactionStatus != .started {
                if turn.isThinking {
                    ShimmeringText.thinking
                } else if !hasActiveTextEntranceAnimation {
                    // Commentary is not `finalText`, but its glyph fade is
                    // still visible activity and wins over this idle fallback.
                    ShimmeringText(text: "Waiting on harness...")
                }
            }

            // The final answer streams here, final-styled from its first
            // chunk: the candidate is the last text span not phase-tagged
            // commentary. It demotes into the worked section only if the
            // provider retro-tags it (Claude preamble before a tool call) or a
            // newer text span starts — codex tags messages up front, so its
            // candidate never demotes.
            if presentation.showsResult,
               let final = finalText, case let .text(entryID, markdown) = final {
                // Selection lives inside each native TextKit run. Keeping it
                // there avoids a selection modifier on the segment VStack and
                // keeps first-click geometry identical to display geometry.
                //
                // isComplete keys the streaming render mode: while generating,
                // the segmenter re-parses only the growing tail and skips
                // text-run merging, so a flush costs O(growing block) instead
                // of O(whole answer). The finalize flip merges runs back into
                // one selectable TextKit storage.
                assistantResponse(entryID: entryID, markdown: markdown)
                if let waitingOnBackgroundTask {
                    ShimmeringText.waitingOnBackgroundTask(waitingOnBackgroundTask)
                }
                if !turn.isGenerating {
                    // Copies just the final answer text, not the worked/tool
                    // content. Hidden until hover so the transcript stays clean.
                    MessageCopyButton(text: markdown, help: "Copy response", isRevealed: isHovered)
                        .opacity(isHovered ? 1 : 0)
                }
            }

            if presentation.showsResult, finalText == nil, !turn.attachments.isEmpty {
                assistantResponse(entryID: "attachments", markdown: "")
            }

            if presentation.showsResult, !isWaitingOnUser, let postResponseGoalActivity {
                ShimmeringText(text: goalActivityLabel(postResponseGoalActivity))
            }

            // A non-clean stop (error / limit / refusal / gave-up retry) surfaces
            // here, attached to this turn — never a silent "stopped for no
            // reason". Clean completions and silently-recovered turns carry no
            // stopDetail and render nothing.
            if presentation.showsResult,
               !turn.isGenerating, let stopDetail = turn.stopDetail {
                turnErrorRow(stopDetail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(StreamingMarkdownEntranceAnimationPreferenceKey.self) { active in
            hasActiveTextEntranceAnimation = active
        }
        // Whole-row hover target, full width and height: AppKit tracking
        // (not .onHover) so the transparent regions count too.
        .hoverTracking($isHovered)
        .onChange(of: turn.isGenerating) { _, generating in
            if generating {
                if !hasAutoCollapsed {
                    for key in sectionKeys { store.setExpanded(key, true) }
                    invalidateRowMeasurement?()
                }
                return
            }
            // Collapse once the assistant message is fully finished, when we
            // know the real final text. Stays collapsed afterward.
            autoCollapse()
        }
        // Provider-asserted finality (codex phase "final") means no more work
        // follows — settle the worked section the moment the answer STARTS
        // streaming instead of waiting for the turn to end.
        .onChange(of: turn.finalTextIsAsserted) { _, asserted in
            if asserted, turn.isGenerating { autoCollapse() }
        }
        // A turn can end while its subagents keep running in the background;
        // the collapse deferred at turn end fires once the last one finishes.
        .onChange(of: turnHasRunningSubagent) { _, running in
            if !running, !turn.isGenerating { autoCollapse() }
        }
    }

    @ViewBuilder
    private func assistantResponse(entryID: String, markdown: String) -> some View {
        let segments = assistantMarkdownSegments(markdown, attachments: turn.attachments)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case let .markdown(value):
                    if !value.isEmpty {
                        StreamingMarkdownView(
                            value,
                            isComplete: !turn.isGenerating,
                            streamID: TranscriptStreamingTextIdentity.main(
                                turnID: turnID,
                                entryID: "\(entryID):\(index)"
                            ),
                            animationPresentation: textAnimationPresentation
                        )
                    }
                case let .attachment(attachment, label):
                    VStack(alignment: .leading, spacing: 4) {
                        AttachmentThumbnailView(attachment: attachment, inline: true)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func retryLabel(_ retry: RetryStatus) -> String {
        guard let attempt = retry.attempt, let of = retry.of else { return retry.message }
        return "\(retry.message) \(attempt)/\(of)"
    }

    @ViewBuilder
    private func turnErrorRow(_ message: String) -> some View {
        if let transcriptController,
           transcriptController.errorRequiresHarnessAuthentication,
           transcriptController.errorMessage == message {
            ChatErrorRow(
                message,
                actionTitle: "Open Harness Settings",
                action: {
                    SettingsRouter.shared.showHarnesses()
                    openSettings()
                }
            )
        } else if let transcriptController,
                  transcriptController.canRetryTurn(turnID) {
            ChatErrorRow(
                message,
                actionTitle: "Retry response",
                action: { Task { await transcriptController.retryTurn(turnID) } }
            )
        } else {
            ChatErrorRow(message)
        }
    }

    private func goalActivityLabel(_ activity: GoalActivity) -> String {
        switch activity {
        case .planning: "Planning…"
        case .verifying: "Verifying…"
        }
    }

    private func autoCollapse() {
        guard !hasAutoCollapsed else { return }
        // Keep the work visible while a subagent is still running in the
        // background; this re-fires from the onChange above once it settles.
        guard !turnHasRunningSubagent else { return }
        hasAutoCollapsed = true
        // Commit layout immediately. The reveal component animates only its
        // pixels; virtual-row height is never an intermediate animation value.
        for key in sectionKeys { store.setExpanded(key, false) }
        // Store-driven: the collapse re-renders entirely inside this row's
        // hosting controller, so explicitly ask the virtualizer to remeasure —
        // settled rows (a turn whose background subagent just finished) have
        // no other layout pass coming.
        invalidateRowMeasurement?()
    }

    /// One "Worked for…" disclosure over `items`, keyed independently so the
    /// planning and implementation sections collapse on their own.
    private func workedSection(
        items: [WorkedItem],
        key: TranscriptDisclosureStore.Key,
        timerLabel: Bool
    ) -> some View {
        let expanded = isExpanded(key)
        return VStack(alignment: .leading, spacing: 12) {
            // Early-collapsed sections (asserted final answer streaming) are
            // already settled: give them the chevron so the user can peek at
            // the work while the answer is still writing.
            if turn.isGenerating, !hasAutoCollapsed {
                workedHeader(label: sectionLabel(timer: timerLabel), showsChevron: false, expanded: expanded)
            } else {
                Button {
                    let change = {
                        if expanded {
                            store.setExpanded(key, false)
                        } else {
                            store.requestReveal(key)
                            store.setExpanded(key, true)
                        }
                        invalidateRowMeasurement?()
                    }
                    performAnchoredDisclosureChange?(change) ?? change()
                } label: {
                    workedHeader(label: sectionLabel(timer: timerLabel), showsChevron: true, expanded: expanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // The divider belongs to the disclosure header, not its revealed
            // contents, so a rendered Worked section keeps the line in both
            // its collapsed and expanded states.
            Divider()

            if expanded && (!items.isEmpty || turn.hasDeferredWorkedDetails) {
                WorkedContentReveal(key: key, store: store) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Answered questions ride here too: the reducer synthesizes
                        // a tool call for each, so they group and render inline with
                        // the other tool calls that surround them.
                        if turn.hasDeferredWorkedDetails,
                           let itemId = turn.deferredDetailItemId,
                           let transcriptController {
                            DeferredTranscriptDetails(controller: transcriptController, itemId: itemId)
                        } else {
                            TranscriptItemsView(
                                items: items,
                                turn: turn,
                                turnID: turnID,
                                isTurnActive: turn.isGenerating,
                                animationPresentation: textAnimationPresentation
                            )
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
        // The worked-section reveal must never animate or displace its label
        // row. The nested chevron still installs its own value-scoped rotation.
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    /// The section label: the live "Working for Xs" / final "Worked for Xs"
    /// timer for the active work, or a static "Planned" for the planning
    /// section once a plan exists (the implementation section carries the
    /// timer from there on).
    @ViewBuilder
    private func sectionLabel(timer: Bool) -> some View {
        if timer {
            if turn.isGenerating {
                TimelineView(.periodic(from: turn.startedAt ?? Date(), by: 1)) { context in
                    Text("Working for \(format(elapsedSeconds(to: context.date)))")
                }
            } else {
                Text(workedTitle)
            }
        } else {
            Text("Planned")
        }
    }

    private func elapsedSeconds(to date: Date) -> Int {
        guard let start = turn.startedAt else { return 0 }
        return max(0, Int(date.timeIntervalSince(start)))
    }

    private func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private var workedTitle: String {
        guard let duration = turn.duration, duration >= 1 else { return "Worked for a moment" }
        return "Worked for \(format(Int(duration.rounded())))"
    }
}

private struct WorkedContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let key: TranscriptDisclosureStore.Key
    let store: TranscriptDisclosureStore
    let revealGeneration: Int
    @State private var isVisible: Bool
    private let content: Content

    init(
        key: TranscriptDisclosureStore.Key,
        store: TranscriptDisclosureStore,
        @ViewBuilder content: () -> Content
    ) {
        self.key = key
        self.store = store
        let generation = store.revealGeneration(for: key)
        revealGeneration = generation
        _isVisible = State(
            initialValue: !store.hasUnclaimedReveal(key, generation: generation)
        )
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : -8)
            .onAppear {
                let shouldAnimate = store.claimReveal(key, generation: revealGeneration)
                guard shouldAnimate, !reduceMotion else {
                    isVisible = true
                    return
                }
                withAnimation(Motion.entrance()) {
                    isVisible = true
                }
            }
    }
}



private struct DeferredTranscriptDetails: View {
    let controller: SessionController
    let itemId: String
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case failed
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ShimmeringText(text: "Loading worked details…")
                .task { await load() }
            case .failed:
                Button("Retry loading worked details") {
                    state = .loading
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private func load() async {
        let loaded = await controller.loadTranscriptDetails(itemId)
        if !loaded {
            state = .failed
        }
    }
}

#Preview("Worked-for expanded") {
    ScrollView {
        if case let .assistant(message) = SampleData.conversation[1] {
            AssistantTurnView(turn: message.turn, initiallyExpanded: true).padding()
        }
    }
    .frame(width: 600, height: 640)
}

#Preview("Thinking") {
    if case let .assistant(message) = SampleData.streamingConversation[1] {
        AssistantTurnView(turn: message.turn).padding().frame(width: 580)
    }
}
