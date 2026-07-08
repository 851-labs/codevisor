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
    /// across the active→settled transition and across culling remounts.
    let turnID: UUID
    private let initiallyExpanded: Bool?
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIds
    /// Transient one-shot guard for the finish/assert auto-collapse. Stays
    /// `@State`: it only matters while the turn is generating/settling, which
    /// is the never-culled active row. A settled remount resets it harmlessly.
    @State private var hasAutoCollapsed = false
    @State private var isHovered = false

    init(turn: AssistantTurn, turnID: UUID = UUID(), initiallyExpanded: Bool? = nil) {
        self.turn = turn
        self.turnID = turnID
        self.initiallyExpanded = initiallyExpanded
        _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
    }

    // Disclosure hoisted to the session store (survives occlusion culling).
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

    /// The planning section shows while the turn is still working toward a plan
    /// (and for any non-plan turn); once a plan exists it shows only if there
    /// was pre-plan work to display.
    private func showsPlanningSection(_ items: [WorkedItem]) -> Bool {
        if turn.planBoundary != nil { return !items.isEmpty }
        return turn.isGenerating || !items.isEmpty
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

            if turn.isThinking {
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
                StreamingMarkdownView(markdown, isComplete: !turn.isGenerating)
                if !turn.isGenerating {
                    // Copies just the final answer text, not the worked/tool
                    // content. Hidden until hover so the transcript stays clean.
                    MessageCopyButton(text: markdown, help: "Copy response", isRevealed: isHovered)
                        .opacity(isHovered ? 1 : 0)
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
        // Animating the removal of an enormous worked section (an
        // hours-long turn is most of the transcript's height) is a
        // main-thread layout hazard; past a size threshold collapse
        // instantly instead.
        let collapse = { for key in sectionKeys { store.setExpanded(key, false) } }
        if turn.entries.count > 80 {
            collapse()
        } else {
            withAnimation(.snappy(duration: 0.28)) { collapse() }
        }
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
                    let settled = !turn.isGenerating || turn.finalTextIsAsserted
                    withAnimation(.snappy(duration: 0.28)) {
                        store.toggle(key, default: initiallyExpanded ?? !settled)
                    }
                } label: {
                    workedHeader(label: sectionLabel(timer: timerLabel), showsChevron: true, expanded: expanded)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if expanded, !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    // Answered questions ride here too: the reducer synthesizes
                    // a tool call for each, so they group and render inline with
                    // the other tool calls that surround them.
                    TranscriptItemsView(items: items, turn: turn, isTurnActive: turn.isGenerating)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
    }

    private func workedHeader(label: some View, showsChevron: Bool, expanded: Bool) -> some View {
        HStack(spacing: 6) {
            label
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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
