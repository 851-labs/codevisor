import SwiftUI
import HerdManCore
import ACPKit
import StreamMarkdown

/// Renders one assistant turn: reasoning text and tool-call groups collapse into
/// a "Worked for…" disclosure, the final answer renders expanded at the bottom,
/// and a shimmering "Thinking..." indicator shows while the agent is working.
struct AssistantTurnView: View {
    let turn: AssistantTurn
    @State private var isExpanded: Bool
    @State private var hasAutoCollapsed = false

    init(turn: AssistantTurn, initiallyExpanded: Bool? = nil) {
        self.turn = turn
        // Expanded while the turn is still running; collapsed once it finishes.
        _isExpanded = State(initialValue: initiallyExpanded ?? turn.isGenerating)
    }

    private var showsWorkedSection: Bool { turn.isGenerating || turn.hasWorkedContent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsWorkedSection {
                workedSection
            }

            if let plan = turn.plan, !plan.entries.isEmpty {
                PlanView(plan: plan)
            }

            if turn.isThinking {
                ShimmeringText.thinking
            }

            if let final = turn.finalText, case let .text(_, markdown) = final {
                StreamingMarkdownView(markdown)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: turn.isGenerating) { _, generating in
            if generating {
                isExpanded = true
                return
            }
            // Collapse only once the assistant message is fully finished, when we
            // know the real final text. Stays collapsed afterward.
            if !hasAutoCollapsed {
                hasAutoCollapsed = true
                withAnimation(.snappy(duration: 0.28)) { isExpanded = false }
            }
        }
    }

    private var workedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if turn.isGenerating {
                workedHeader(showsChevron: false)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
                } label: {
                    workedHeader(showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded && !turn.workedItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    ForEach(turn.workedItems) { item in
                        switch item {
                        case let .text(_, markdown):
                            StreamingMarkdownView(markdown)
                                .foregroundStyle(.secondary)
                        case let .toolGroup(_, calls):
                            ToolGroupView(calls: calls)
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
    }

    private func workedHeader(showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            label
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The worked-for label: a live-incrementing "Working for Xs" while the turn
    /// is running, or a final "Worked for Xs" once done.
    @ViewBuilder
    private var label: some View {
        if turn.isGenerating {
            TimelineView(.periodic(from: turn.startedAt ?? Date(), by: 1)) { context in
                Text("Working for \(format(elapsedSeconds(to: context.date)))")
            }
        } else {
            Text(workedTitle)
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
