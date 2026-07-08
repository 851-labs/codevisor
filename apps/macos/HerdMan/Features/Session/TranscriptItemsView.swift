import SwiftUI
import ACPKit
import HerdManCore
import StreamMarkdown

/// Renders a list of worked items — reasoning text, tool groups, and subagent
/// sections. Shared by the top-level turn transcript and each nested subagent
/// section, so a subagent's thread is literally the same UI, one level down.
struct TranscriptItemsView: View {
    let items: [WorkedItem]
    /// The owning turn: subagent threads are looked up here by tool call id.
    let turn: AssistantTurn
    let isTurnActive: Bool
    var depth: Int = 0

    /// Depth at which further subagent sections render as plain tool rows.
    /// Real nesting is one level (subagents can't spawn subagents today);
    /// the cap is a rendering guard, not a data limit.
    private static let maxNestingDepth = 3

    var body: some View {
        ForEach(items) { item in
            switch item {
            case let .text(_, markdown):
                // Streaming render mode while the turn is live: commentary
                // spans stream the same way the final answer does, so they get
                // the same O(growing block) per-flush cost bound.
                StreamingMarkdownView(markdown, isComplete: !isTurnActive)
                    .foregroundStyle(.secondary)
            case let .toolGroup(_, calls):
                ToolGroupView(
                    calls: calls,
                    isTurnActive: isTurnActive,
                    // Follow-the-work auto-expansion tracks the main thread
                    // only; nested groups stay manual to keep sections calm.
                    autoExpanded: depth == 0 && isTurnActive
                        && (calls.last.map { turn.isTrailingToolGroup(lastToolCallId: $0.toolCallId) } ?? false)
                )
            case let .subagent(_, call):
                if depth + 1 < Self.maxNestingDepth {
                    SubagentSectionView(call: call, turn: turn, isTurnActive: isTurnActive, depth: depth + 1)
                } else {
                    ToolCallRow(call: call, isTurnActive: isTurnActive)
                }
            }
        }
    }
}

/// A subagent's thread, inline in the chat: a collapsible header row (the
/// Task tool call) whose body is the subagent's own transcript rendered with
/// the same components as the parent turn.
struct SubagentSectionView: View {
    let call: ToolCall
    let turn: AssistantTurn
    let isTurnActive: Bool
    let depth: Int
    @Environment(\.theme) private var theme
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagentToolCallIds
    /// Transient one-shot guard for the settle collapse. Stays `@State`: it
    /// only matters while the subagent is running/settling, which happens in
    /// the never-culled active row. A settled remount resets it harmlessly
    /// (the settle onChange can't re-fire without a state change).
    @State private var hasAutoCollapsed = false

    // Disclosure hoisted to the session store (survives occlusion culling).
    // Default open while running, collapsed when revisiting a finished thread.
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var disclosureKey: TranscriptDisclosureStore.Key { .subagent(call.toolCallId) }
    private var isExpanded: Bool {
        store.isExpanded(disclosureKey, default: isRunning)
    }

    /// Running while the turn is live and the call is open, OR — once the turn
    /// has ended — while the subagent is still working in the background (its
    /// call was force-settled at turn end, so the background snapshot is the
    /// only remaining signal that it's alive).
    private var isRunning: Bool {
        (isTurnActive && !call.isSettled) || runningSubagentToolCallIds.contains(call.toolCallId)
    }
    private var items: [WorkedItem] { turn.subagentItems(call.toolCallId) }
    private var transcript: SubagentTranscript? { turn.subagents[call.toolCallId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    TranscriptItemsView(items: items, turn: turn, isTurnActive: isTurnActive, depth: depth)
                    if isRunning, transcript?.isThinking == true {
                        ShimmeringText.thinking
                    } else if isRunning, items.isEmpty {
                        ShimmeringText.startingAgent
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
        // Collapse once the subagent stops running — including background work
        // that outlives the turn; manual toggles still work after.
        .onChange(of: isRunning) { _, running in
            if !running, !hasAutoCollapsed {
                hasAutoCollapsed = true
                withAnimation(.snappy(duration: 0.25)) { store.setExpanded(disclosureKey, false) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.sparkles")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(call.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .shimmering(isRunning)
            statusGlyph
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) {
                store.toggle(disclosureKey, default: isRunning)
            }
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch call.status {
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.caption)
                .foregroundStyle(theme.statusError)
        case .cancelled:
            Image(systemName: "slash.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

#Preview("Subagent section") {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(
        .toolCall(ToolCall(toolCallId: "task-1", title: "Agent: map the chat UI", kind: .agent, status: .inProgress)),
        to: &turn
    )
    TranscriptReducer.apply(
        .agentMessageChunk(.text("Scanning the session views first."), messageId: "msg-sub", parentToolCallId: "task-1"),
        to: &turn
    )
    TranscriptReducer.apply(
        .toolCall(ToolCall(toolCallId: "sub-1", title: "Read SessionView.swift", kind: .read, status: .completed, parentToolCallId: "task-1")),
        to: &turn
    )
    TranscriptReducer.apply(
        .toolCall(ToolCall(toolCallId: "sub-2", title: "Searched for streamFingerprint", kind: .search, status: .inProgress, parentToolCallId: "task-1")),
        to: &turn
    )
    return ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            TranscriptItemsView(items: turn.streamingItems, turn: turn, isTurnActive: true)
        }
        .padding()
    }
    .frame(width: 560, height: 320)
}
