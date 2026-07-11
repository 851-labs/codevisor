import SwiftUI
import HerdManCore
import ACPKit
import StreamMarkdown

/// Renders one assistant turn: reasoning text and tool-call groups collapse into
/// a "Worked for…" disclosure, the final answer renders expanded at the bottom,
/// and a shimmering "Thinking..." indicator shows while the agent is working.
struct AssistantTurnView: View {
    let turn: AssistantTurn
    /// Stable id of the owning assistant message — the disclosure key, stable
    /// across the active→settled transition and lazy remounts.
    let turnID: UUID
    private let initiallyExpanded: Bool?
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIds
    @Environment(\.transcriptController) private var transcriptController
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
    @Environment(\.theme) private var theme
    /// Transient one-shot guard for the finish/assert auto-collapse. Stays
    /// `@State`: it only matters while the turn is generating/settling, which
    /// is the mounted active row. A settled remount resets it harmlessly.
    @State private var hasAutoCollapsed = false
    @State private var isHovered = false

    init(turn: AssistantTurn, turnID: UUID = UUID(), initiallyExpanded: Bool? = nil) {
        self.turn = turn
        self.turnID = turnID
        self.initiallyExpanded = initiallyExpanded
        _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
    }

    // Disclosure hoisted to the session store so lazy remounts preserve it.
    // The default reproduces the old init seeding: expanded while running,
    // collapsed once finished / when a provider-asserted final is streaming.
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

    /// Both worked sections: planning (above the plan card) and the
    /// implementation that follows approval (below it).
    private var sectionKeys: [TranscriptDisclosureStore.Key] {
        [.turn(turnID), .turnImplementation(turnID)]
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
        let beforePlan = turn.workedItemsBeforePlan
        let afterPlan = turn.workedItemsAfterPlan
        VStack(alignment: .leading, spacing: 14) {
            // Planning/exploration collapses into the first "Worked for…"
            // section, above the proposed plan.
            if showsPlanningSection(beforePlan) {
                workedSection(items: beforePlan, key: .turn(turnID), timerLabel: turn.planBoundary == nil)
            }

            if let planDocument = turn.planDocument, !planDocument.isEmpty {
                PlanDocumentView(markdown: planDocument)
            }
            // The step checklist lives in the pinned TodoPanelView above the
            // composer (session-level, all harnesses) rather than per turn.

            // Once the plan is approved, the implementation gets its own
            // "Worked for…" section BELOW the plan, so approved work reads in
            // order (plan → build) instead of piling up above the plan card.
            if !afterPlan.isEmpty {
                workedSection(items: afterPlan, key: .turnImplementation(turnID), timerLabel: true)
            }

            // A transient failure (e.g. 529 overload) is being retried — show it
            // instead of the plain "Thinking…" so the chat isn't a silent freeze.
            if turn.isGenerating, let retry = turn.retryStatus {
                ShimmeringText(text: "Retrying… (\(retry.attempt)/\(retry.of))")
            } else if turn.showsActivityIndicator {
                ShimmeringText.thinking
            }

            // The final answer streams here, final-styled from its first
            // chunk: the candidate is the last text span not phase-tagged
            // commentary. It demotes into the worked section only if the
            // provider retro-tags it (Claude preamble before a tool call) or a
            // newer text span starts — codex tags messages up front, so its
            // candidate never demotes.
            if let final = turn.finalText, case let .text(_, markdown) = final {
                // No .textSelection here: the Texts inside StreamingMarkdownView
                // already enable it per-run. Applying it again on the whole
                // segment stack forces the entire VStack through the selection
                // layout path on first click, causing a visible layout shift.
                //
                // isComplete keys the streaming render mode: while generating,
                // the segmenter re-parses only the growing tail and skips
                // text-run merging, so a flush costs O(growing block) instead
                // of O(whole answer). The finalize flip merges runs back into
                // one selectable Text.
                StreamingMarkdownView(
                    markdown,
                    isComplete: !turn.isGenerating
                )
                if !turn.isGenerating {
                    // Copies just the final answer text, not the worked/tool
                    // content. Hidden until hover so the transcript stays clean.
                    MessageCopyButton(text: markdown, help: "Copy response", isRevealed: isHovered)
                        .opacity(isHovered ? 1 : 0)
                }
            }

            // A non-clean stop (error / limit / refusal / gave-up retry) surfaces
            // here, attached to this turn — never a silent "stopped for no
            // reason". Clean completions and silently-recovered turns carry no
            // stopDetail and render nothing.
            if !turn.isGenerating, let stopDetail = turn.stopDetail {
                if turn.finalText == nil {
                    // No answer was produced (e.g. an exhausted 529 retry): show
                    // the error in the answer slot, in red.
                    Text(stopDetail)
                        .font(.callout)
                        .foregroundStyle(theme.statusError)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // An answer did stream (e.g. a refusal note); mark the reason
                    // as a compact red line beneath it.
                    Label(stopDetail, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(theme.statusError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Whole-row hover target, full width and height: AppKit tracking
        // (not .onHover) so the transparent regions count too.
        .hoverTracking($isHovered)
        .onChange(of: turn.isGenerating) { _, generating in
            if generating {
                if !hasAutoCollapsed {
                    for key in sectionKeys { store.setExpanded(key, true) }
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

    private func autoCollapse() {
        guard !hasAutoCollapsed else { return }
        // Keep the work visible while a subagent is still running in the
        // background; this re-fires from the onChange above once it settles.
        guard !turnHasRunningSubagent else { return }
        hasAutoCollapsed = true
        // Commit layout immediately. The reveal component animates only its
        // pixels; virtual-row height is never an intermediate animation value.
        for key in sectionKeys { store.setExpanded(key, false) }
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
                            TranscriptItemsView(items: items, turn: turn, isTurnActive: turn.isGenerating)
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

/// The disclosure indicator owns its rotation animation. The section body has
/// a separate entrance animation, so the label and chevron never fade or move
/// with the expanded content.
struct TranscriptDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 10, height: 10)
            // Scope interpolation to rotation only. A value-based animation
            // also captured position changes from the expanding parent.
            .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
                chevron.rotationEffect(.degrees(expanded ? 90 : 0))
            }
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

struct TranscriptDisclosureContentReveal<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    @State private var phase: Phase
    @State private var measuredHeight: CGFloat = 0
    @State private var presentedHeight: CGFloat?
    @State private var presentedOpacity: CGFloat
    @State private var animationGeneration = 0
    private let content: Content

    private enum Phase {
        case collapsed
        case measuring
        case expanding
        case expanded
        case collapsing
    }

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        _phase = State(initialValue: isExpanded ? .expanded : .collapsed)
        _presentedHeight = State(initialValue: isExpanded ? nil : 0)
        _presentedOpacity = State(initialValue: isExpanded ? 1 : 0)
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        Group {
            if phase != .collapsed {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DisclosureContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                    // Scope interpolation to these presentation modifiers.
                    // The enclosing tool group, Worked section, and message
                    // root receive ordinary layout updates, never this
                    // animation transaction.
                    .animation(Motion.reveal(reduceMotion: reduceMotion)) { body in
                        body
                            .opacity(presentedOpacity)
                            .frame(height: presentedHeight, alignment: .top)
                    }
                    .clipped()
                    .allowsHitTesting(phase == .expanded)
            }
        }
        .onPreferenceChange(DisclosureContentHeightKey.self) { height in
            guard height > 0 else { return }
            measuredHeight = height
            if phase == .measuring {
                expandMeasuredContent(to: height)
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            setExpanded(expanded)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if reduceMotion {
            animationGeneration &+= 1
            phase = expanded ? .expanded : .collapsed
            presentedHeight = expanded ? nil : 0
            presentedOpacity = expanded ? 1 : 0
            return
        }

        if expanded {
            switch phase {
            case .collapsed:
                presentedHeight = 0
                presentedOpacity = 0
                phase = .measuring
            case .collapsing:
                phase = .expanding
                presentedHeight = measuredHeight > 0 ? measuredHeight : nil
                presentedOpacity = 1
                scheduleSettlement(expanded: true)
            case .measuring, .expanding, .expanded:
                break
            }
        } else {
            switch phase {
            case .measuring:
                phase = .collapsed
                presentedHeight = 0
                presentedOpacity = 0
            case .expanding, .expanded:
                phase = .collapsing
                presentedHeight = measuredHeight > 0 ? measuredHeight : presentedHeight
                presentedHeight = 0
                presentedOpacity = 0
                scheduleSettlement(expanded: false)
            case .collapsed, .collapsing:
                break
            }
        }
    }

    private func expandMeasuredContent(to height: CGFloat) {
        guard isExpanded, phase == .measuring else { return }
        phase = .expanding
        presentedHeight = height
        presentedOpacity = 1
        scheduleSettlement(expanded: true)
    }

    private func scheduleSettlement(expanded: Bool) {
        animationGeneration &+= 1
        let generation = animationGeneration
        Task { @MainActor in
            try? await Task.sleep(for: Motion.revealSettleDelay)
            guard generation == animationGeneration,
                  isExpanded == expanded else { return }
            if expanded {
                guard phase == .expanding else { return }
                phase = .expanded
                presentedHeight = nil
            } else {
                guard phase == .collapsing else { return }
                phase = .collapsed
            }
        }
    }
}

private struct DisclosureContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading worked details…").foregroundStyle(.secondary)
                }
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
