import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// The macOS SubagentSectionView: a wand header shimmering while the
/// subagent runs, its transcript recursing beneath.
struct SubagentSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.runningSubagentToolCallIds) private var runningSubagents
    @Environment(\.transcriptPerformAnchoredDisclosureChange)
    private var performAnchoredDisclosureChange
    @State private var hasAutoCollapsed = false
    let call: ToolCall
    let turn: AssistantTurn
    let turnId: UUID
    let depth: Int
    let isTurnActive: Bool
    let animationPresentation: StreamingTextAnimationPresentation

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var key: TranscriptDisclosureStore.Key { .subagent(call.toolCallId) }

    private var isRunning: Bool {
        (isTurnActive && !call.isSettled) || runningSubagents.contains(call.toolCallId)
    }

    private var items: [WorkedItem] { turn.subagentItems(call.toolCallId) }
    private var transcript: SubagentTranscript? { turn.subagents[call.toolCallId] }

    var body: some View {
        let isExpanded = store.isExpanded(key, default: isRunning)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    // One notch under the callout label, like the tool group
                    // icon — the macOS transcript's icon-under-text ratio.
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 16, relativeTo: .subheadline)
                Text(call.displayTitle)
                    .foregroundStyle(.secondary)
                    // Expanding reveals child items, not this title — reflow
                    // at accessibility sizes instead of truncating.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.tail)
                    .shimmering(isRunning)
                statusGlyph
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture {
                let change = { store.toggle(key, default: isRunning) }
                performAnchoredDisclosureChange?(change) ?? change()
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TurnItemsView(
                        items: items,
                        turn: turn,
                        turnId: turnId,
                        depth: depth + 1,
                        isTurnActive: isTurnActive,
                        animationPresentation: animationPresentation,
                        parentToolCallID: call.toolCallId
                    )
                    if isRunning, transcript?.isThinking == true {
                        ShimmeringText.thinking
                    } else if isRunning, items.isEmpty {
                        ShimmeringText.startingAgent
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 8)
            }
        }
        .onChange(of: isRunning) { _, running in
            if !running, !hasAutoCollapsed {
                hasAutoCollapsed = true
                store.setExpanded(key, false)
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
